import Foundation

/// A workflow pattern turned into something a human can read: a plain-language
/// name, what the process actually is (grounded in the captured storyline), what
/// could be automated, and the real screenshots + narratives to drill into.
///
/// Everything is tied to the workflow's *steps* — the (app, window-title) pairs
/// the pattern is made of — NOT merely to its time window. That distinction is
/// what stops unrelated concurrent activity (a CRM tab open during an invoice
/// run) from being mislabeled as part of this workflow.
struct WorkflowInsight: Equatable {
    var pattern: WorkflowPattern
    var title: String
    var whatItIs: String
    var whatToAutomate: String
    /// Whether this is a genuine automation candidate (there is hard mechanical
    /// evidence — cross-app data transfer or consistent structured field entry),
    /// as opposed to reading/analysis/writing that a person has to do.
    var automatable: Bool
    /// One representative run's captured moments (screenshot + narrative), in order.
    var moments: [SceneNarrative]
    /// The step map: app + the representative window/tab at that step.
    var steps: [Step]

    struct Step: Identifiable, Equatable {
        var id: Int
        var app: String
        var detail: String
    }
}

enum WorkflowInsighter {

    static func build(_ pattern: WorkflowPattern, store: Store, demo: Bool) -> WorkflowInsight {
        let steps = buildSteps(pattern)
        let matcher = StepMatcher(steps: steps)

        // For each occurrence window, pull the raw data then keep ONLY what
        // belongs to this workflow's steps.
        var occSpans: [[ActivitySpan]] = []
        var occNarr: [[SceneNarrative]] = []
        for w in pattern.windows {
            let spans = store.spans(from: w.start, to: w.end.addingTimeInterval(1), demo: demo)
                .filter { matcher.matches(app: $0.appName, title: $0.windowTitle) }
            let narrs = store.narratives(from: w.start, to: w.end.addingTimeInterval(1), demo: demo)
                .filter { matcher.matches(app: $0.appName, title: $0.windowTitle) }
                .sorted { $0.timestamp < $1.timestamp }
            occSpans.append(spans)
            occNarr.append(narrs)
        }
        // Representative run = the occurrence with the most captured moments.
        let moments = occNarr.max(by: { $0.count < $1.count }) ?? []
        let analysis = analyzeAutomation(pattern: pattern, occSpans: occSpans, narratives: occNarr.flatMap { $0 })

        return WorkflowInsight(
            pattern: pattern,
            title: deriveTitle(pattern: pattern, steps: steps),
            whatItIs: deriveWhatItIs(pattern: pattern, moments: moments, steps: steps),
            whatToAutomate: analysis.text,
            automatable: analysis.automatable,
            moments: moments,
            steps: steps
        )
    }

    // MARK: - Step matching

    /// Decides whether a captured span/narrative belongs to this workflow: its
    /// UNIT (site/service for browsers, app otherwise) must be one of the
    /// workflow's units. Because the unit already encodes the site, this cleanly
    /// separates Chrome/NetSuite from Chrome/Temu.
    private struct StepMatcher {
        private let units: Set<String>
        init(steps: [WorkflowInsight.Step]) { units = Set(steps.map(\.app)) }
        func matches(app: String, title: String) -> Bool {
            units.contains(WorkflowUnit.label(app: app, title: title))
        }
    }

    // MARK: - Steps

    static func buildSteps(_ pattern: WorkflowPattern) -> [WorkflowInsight.Step] {
        // pattern.apps are already units (site/service for browsers).
        pattern.apps.enumerated().map { i, unit in
            let label = i < pattern.stepLabels.count ? pattern.stepLabels[i] : ""
            return WorkflowInsight.Step(id: i, app: unit, detail: label)
        }
    }

    // MARK: - Title

    static func deriveTitle(pattern: WorkflowPattern, steps: [WorkflowInsight.Step]) -> String {
        // Anchor on the most recognizable step — a document or a named record
        // (has a file extension, or an em-dash "Record — System" shape). Prefer a
        // later step (usually the destination system), which reads as the goal.
        let specific = steps.filter { isSpecific($0.detail) }
        if let anchor = specific.last?.detail { return anchor }
        // Otherwise a distinct app pairing — still clearer than a raw chain.
        let apps = distinct(pattern.apps.map(shortApp))
        if apps.count >= 2 { return "\(apps[0]) ⇄ \(apps[1]) routine" }
        return (apps.first ?? "Repeated") + " routine"
    }

    /// A title we can lead with: names a document or a specific record, not a
    /// generic tab like "New Tab" or "Sign in".
    private static func isSpecific(_ label: String) -> Bool {
        guard !label.isEmpty else { return false }
        if label.range(of: #"\.\w{2,5}$"#, options: .regularExpression) != nil { return true } // file.ext
        if label.contains("—") || label.contains("–") || label.contains("|") { return true }    // Record — System
        let generic: Set<String> = ["new tab", "sign in", "home", "untitled", "inbox", "loading", "settings"]
        let lower = label.lowercased()
        if generic.contains(where: { lower.hasPrefix($0) }) { return false }
        return label.split(separator: " ").count >= 3
    }

    // MARK: - What it is

    static func deriveWhatItIs(pattern: WorkflowPattern, moments: [SceneNarrative], steps: [WorkflowInsight.Step]) -> String {
        // Prefer a coherent, TIME-ORDERED walk of one representative run — this
        // reads as an actual sequence, not a frequency jumble.
        let ordered = dedupConsecutive(moments.map(\.text).filter { !$0.isEmpty && $0 != "Away from keyboard" })
        if !ordered.isEmpty {
            return ordered.prefix(4).joined(separator: " → ").capitalizingFirst()
        }
        // No storyline captured — describe the observed app/tab sequence plainly.
        let labeled = steps.filter { !$0.detail.isEmpty }
        if !labeled.isEmpty {
            let chain = labeled.map { "\($0.app) (\($0.detail))" }.joined(separator: " → ")
            return "A repeated move through: \(chain)."
        }
        let apps = distinct(pattern.apps.map(shortApp))
        return "You switched between \(apps.joined(separator: ", ")) in the same order \(pattern.occurrences) times. Turn on Storyline (Privacy tab) to capture what happens at each step."
    }

    // MARK: - What to automate (evidence-gated, honest about cognitive work)

    /// Only calls something automatable when there is HARD mechanical evidence —
    /// data moved between different systems, or the same real fields entered on
    /// most runs. Repetition alone (e.g. bouncing between a browser and a chat
    /// app while thinking) is NOT enough: that's reading/analysis a person does,
    /// and we say so plainly instead of inventing a bogus dollar figure.
    static func analyzeAutomation(pattern: WorkflowPattern, occSpans: [[ActivitySpan]], narratives: [SceneNarrative]) -> (text: String, automatable: Bool) {
        let allSpans = occSpans.flatMap { $0 }

        // 1. Cross-system data transfer: copy in one app, paste in a different one.
        let copyApp = mostCommonApp(allSpans.filter { $0.shortcuts.contains("⌘C") })
        let pasteApp = mostCommonApp(allSpans.filter { $0.shortcuts.contains("⌘V") })
        let crossAppTransfer = copyApp != nil && pasteApp != nil && copyApp != pasteApp

        // 2. Consistent structured field entry: real field names entered on most
        //    runs (not UI hint text, and not a form the user touched only once).
        let consistentFields = consistentFieldNames(occSpans)

        let mechanical = crossAppTransfer || !consistentFields.isEmpty

        // 3. Cognitive signal from the narratives — reading, analysing, writing.
        let cognitive = dominantCognitiveKind(narratives)

        var parts: [String] = []

        if mechanical {
            if let copyApp, let pasteApp, crossAppTransfer {
                parts.append("You move data from \(copyApp) into \(pasteApp) by hand each time — an automation could transfer it directly via their APIs, removing the copy-and-paste.")
            }
            if !consistentFields.isEmpty {
                parts.append("The same fields are entered on most runs (\(consistentFields.joined(separator: ", "))) — these could be auto-filled from the source instead of typed.")
            }
            if pattern.projectionIsReliable {
                parts.append("At the observed rate that's about \(Format.hours(pattern.estimatedHoursPerYear)) a year.")
            }
            return (parts.joined(separator: " "), true)
        }

        // No mechanical evidence → be honest: this is thinking work, not a task.
        if let cognitive {
            return ("This looks mostly like \(cognitive) — the kind of judgement and thinking work a person does, not a mechanical task. It isn't a strong automation candidate. (An AI can *assist* here, but it can't run it unattended.)", false)
        }
        let apps = distinct(pattern.apps.map(shortApp))
        return ("You repeat this move between \(apps.joined(separator: ", ")), but there's no sign of data being moved or forms being filled — so it looks like navigation or reading rather than a task to automate. Turn on Storyline (Privacy tab) to capture more detail, or treat this as low-priority.", false)
    }

    /// Field names that appear on at least half the occurrences, after stripping
    /// UI hint text / placeholders that aren't real form fields.
    static func consistentFieldNames(_ occSpans: [[ActivitySpan]]) -> [String] {
        guard !occSpans.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for occ in occSpans {
            var seen = Set<String>()
            for span in occ {
                for raw in span.fields.split(separator: ",") {
                    guard let name = cleanFieldName(String(raw)) else { continue }
                    if !seen.contains(name) { seen.insert(name); counts[name, default: 0] += 1 }
                }
            }
        }
        let threshold = max(2, (occSpans.count + 1) / 2) // ≥ half the runs, min 2
        return counts.filter { $0.value >= threshold }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(6).map(\.key)
    }

    /// Turns a captured field label into a real field name, or nil if it's UI
    /// chrome (a call-to-action, placeholder, or instruction) rather than a field.
    static func cleanFieldName(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression) // drop [class]
        s = s.replacingOccurrences(of: #"\s*\((optional|required)\)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let lower = s.lowercased()
        // Instruction / CTA / placeholder text is not a field name.
        let ctaStarts = ["press ", "ask ", "chat with", "message ", "search", "click", "send ", "type ", "write your", "enter to", "tab then", "sign in", "log in", "continue with", "get started", "learn more"]
        if ctaStarts.contains(where: { lower.hasPrefix($0) }) { return nil }
        if lower.contains(" to ") && lower.split(separator: " ").count > 4 { return nil } // sentence-like hint
        if s.count < 2 || s.count > 32 { return nil } // real field names are short
        return s
    }

    /// The dominant kind of cognitive work in the narratives, or nil if the
    /// narratives look task-like rather than thinking-like.
    static func dominantCognitiveKind(_ narratives: [SceneNarrative]) -> String? {
        guard !narratives.isEmpty else { return nil }
        let text = narratives.map { $0.text.lowercased() }.joined(separator: " ")
        let categories: [(String, [String])] = [
            ("reading and analysis", ["review", "read", "analy", "research", "discuss", "explor", "evaluat", "assess", "consider", "compar", "study", "look"]),
            ("writing", ["writ", "draft", "compos", "edit", "respond", "reply", "author"]),
            ("browsing", ["brows", "scroll", "navigat", "watch"]),
            ("planning", ["plan", "brainstorm", "outlin", "strateg"]),
        ]
        let mechanicalHits = ["enter", "fill", "submit", "copy", "past", "download", "upload", "creat", "record", "post", "sync", "transfer", "process", "search for"].reduce(0) { $0 + occurrences(of: $1, in: text) }
        var best: (String, Int)?
        for (name, verbs) in categories {
            let hits = verbs.reduce(0) { $0 + occurrences(of: $1, in: text) }
            if hits > (best?.1 ?? 0) { best = (name, hits) }
        }
        guard let best, best.1 > 0, best.1 >= mechanicalHits else { return nil }
        return best.0
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - Helpers

    static func shortApp(_ name: String) -> String {
        name.replacingOccurrences(of: "Microsoft ", with: "").replacingOccurrences(of: "Google ", with: "")
    }

    /// Most common workflow UNIT among spans (site/service for browsers), so a
    /// copy/paste transfer names "Excel → NetSuite", not "Chrome → Chrome".
    private static func mostCommonApp(_ spans: [ActivitySpan]) -> String? {
        var counts: [String: Int] = [:]
        for s in spans { counts[WorkflowUnit.label(app: s.appName, title: s.windowTitle), default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key
    }

    private static func distinct(_ xs: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for x in xs where !seen.contains(x) { seen.insert(x); out.append(x) }
        return out
    }

    private static func dedupConsecutive(_ xs: [String]) -> [String] {
        var out: [String] = []
        for x in xs where out.last != x { out.append(x) }
        return out
    }
}

private extension String {
    func capitalizingFirst() -> String {
        guard let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}
