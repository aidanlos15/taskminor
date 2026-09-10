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
        /// A detailed account of what happened AT this step, from the captured
        /// narratives — so the step map is vivid, not just an app name.
        var content: String = ""
    }
}

enum WorkflowInsighter {

    /// Padding around each occurrence window so captures that land just outside
    /// the tight boundary (the model runs behind) are still attached.
    private static let windowPad: TimeInterval = 120

    static func build(_ pattern: WorkflowPattern, store: Store, demo: Bool) -> WorkflowInsight {
        var steps = buildSteps(pattern)
        let matcher = StepMatcher(steps: steps)

        // Pull all captured data across the workflow's whole (padded) span once,
        // then keep only what belongs to its steps (by unit).
        let starts = pattern.windows.map(\.start)
        let ends = pattern.windows.map(\.end)
        let spanStart = (starts.min() ?? .distantPast).addingTimeInterval(-windowPad)
        let spanEnd = (ends.max() ?? Date()).addingTimeInterval(windowPad)
        let allNarr = store.narratives(from: spanStart, to: spanEnd, demo: demo)
            .filter { matcher.matches(app: $0.appName, title: $0.windowTitle) }
            .sorted { $0.timestamp < $1.timestamp }
        let allSpansMatched = store.spans(from: spanStart, to: spanEnd, demo: demo)
            .filter { matcher.matches(app: $0.appName, title: $0.windowTitle) }

        // Per occurrence (padded) for spans (automation analysis) and for the
        // representative walkthrough.
        var occSpans: [[ActivitySpan]] = []
        var occNarr: [[SceneNarrative]] = []
        for w in pattern.windows {
            let a = w.start.addingTimeInterval(-windowPad), b = w.end.addingTimeInterval(windowPad)
            occSpans.append(allSpansMatched.filter { $0.end > a && $0.start < b })
            occNarr.append(allNarr.filter { $0.timestamp >= a && $0.timestamp <= b })
        }
        // Representative run = the occurrence with the most captured moments. If
        // nothing landed inside ANY occurrence we leave this empty and show an
        // honest "no detail yet" state — never dress up content from the gaps
        // between runs as if it were a real run of this workflow.
        let moments = occNarr.max(by: { $0.count < $1.count }) ?? []

        // Content pool for the step map and the cognitive read: ONLY narratives
        // captured inside the workflow's own occurrences (deduped by id), never
        // the gaps between them — so unrelated same-unit work (e.g. a personal
        // spreadsheet opened in Excel between invoice runs) can't leak into a step.
        var runNarr: [SceneNarrative] = []
        var seenIDs = Set<Int64>()
        for occ in occNarr {
            for n in occ where !seenIDs.contains(n.id) { seenIDs.insert(n.id); runNarr.append(n) }
        }

        // Per-step detail: the richest in-occurrence narrative for each step's
        // unit. A unit that recurs at two steps (e.g. Notes → browser → Notes)
        // gets a DIFFERENT moment at each step (richest-first, no reuse), so the
        // steps never read as byte-identical.
        var byUnit: [String: [SceneNarrative]] = [:]
        for n in runNarr { byUnit[WorkflowUnit.label(app: n.appName, title: n.windowTitle), default: []].append(n) }
        for k in byUnit.keys { byUnit[k]?.sort { $0.text.count > $1.text.count } }
        var usedIDs = Set<Int64>()
        for i in steps.indices {
            let pool = byUnit[steps[i].app] ?? []
            let pick = pool.first { !usedIDs.contains($0.id) } ?? pool.first
            if let pick { usedIDs.insert(pick.id) }
            steps[i].content = pick?.text ?? ""
        }

        // One judgement for the whole app. A transfer-derived pattern arrives with
        // its verdict already computed by the miner; a sequence-derived one is
        // judged here from the same Evidence shape, so the Workflows tab and the
        // Story cards can never disagree about the same work.
        var pattern = pattern
        if pattern.verdict == nil {
            let runTransfers = pattern.windows.flatMap { w in
                store.transfers(from: w.start.addingTimeInterval(-windowPad), to: w.end.addingTimeInterval(windowPad), demo: demo)
            }
            let evidence = Evidence.gather(
                occSpans: occSpans,
                transfers: runTransfers,
                daysObserved: pattern.daysSeenOrObserved,
                durations: occSpans.map { run in run.reduce(0.0) { $0 + $1.duration } }
            )
            let v = Verdict.assess(evidence)
            pattern.verdict = v
            pattern.automationScore = v.score
            pattern.fields = evidence.consistentFields
            pattern.transferCount = runTransfers.count
        }
        let analysis = analyzeAutomation(pattern: pattern, occSpans: occSpans, narratives: runNarr)

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
        // The verdict decides; this only explains it in words. Before, this
        // function made its own call from one window's worth of activity, so a
        // developer checking email read as highly automatable.
        if let v = pattern.verdict {
            return (explain(verdict: v, pattern: pattern, occSpans: occSpans, narratives: narratives), v.isCandidate)
        }
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
        return ("You repeat this move between \(apps.joined(separator: ", ")), but nothing was moved and no forms were filled. It looks like reading or navigating rather than a task to automate. Turn on screen capture in the Privacy tab to capture more detail, or treat this as low priority.", false)
    }

    /// Puts the shared verdict into words, with the specifics that earned it.
    static func explain(verdict v: Verdict, pattern: WorkflowPattern, occSpans: [[ActivitySpan]], narratives: [SceneNarrative]) -> String {
        var parts: [String] = []
        switch v.level {
        case .insufficient:
            parts.append("Seen \(pattern.occurrences) time\(pattern.occurrences == 1 ? "" : "s") across \(pattern.daysSeenOrObserved) day\(pattern.daysSeenOrObserved == 1 ? "" : "s"). Availeth waits for \(Verdict.minOccurrences) runs on \(Verdict.minDays) separate days before judging whether something is worth automating, so that a busy hour is never mistaken for a routine.")
        case .low:
            let apps = distinct(pattern.apps.map(shortApp))
            parts.append("You repeat this move between \(apps.joined(separator: ", ")), but the evidence points away from a chore: \(v.reasons.joined(separator: ", ")).")
            if let cognitive = dominantCognitiveKind(narratives) {
                parts.append("It looks mostly like \(cognitive), which a person does rather than a rule.")
            }
        case .medium, .high:
            let allSpans = occSpans.flatMap { $0 }
            let copyApp = mostCommonApp(allSpans.filter { $0.shortcuts.contains("⌘C") })
            let pasteApp = mostCommonApp(allSpans.filter { $0.shortcuts.contains("⌘V") })
            if pattern.transferCount > 0, let copyApp, let pasteApp, copyApp != pasteApp {
                parts.append("Data is carried from \(copyApp) into \(pasteApp) by hand, \(pattern.transferCount) time\(pattern.transferCount == 1 ? "" : "s") across the runs Availeth watched. An automation could pass it straight between their APIs.")
            } else if pattern.transferCount > 0 {
                parts.append("Data is carried between these steps by hand, \(pattern.transferCount) time\(pattern.transferCount == 1 ? "" : "s") across the runs Availeth watched.")
            }
            if !pattern.fields.isEmpty {
                parts.append("The same fields are filled on most runs (\(pattern.fields.prefix(5).joined(separator: ", "))), so they could be filled from the source instead of typed.")
            }
            parts.append("Seen \(pattern.occurrences) times across \(pattern.daysSeenOrObserved) days, out of \(pattern.daysObserved) working day\(pattern.daysObserved == 1 ? "" : "s") watched.")
            if pattern.projectionIsReliable {
                parts.append("At the rate observed, that is about \(Format.hours(pattern.estimatedHoursPerYear)) a year.")
            }
        }
        return parts.joined(separator: " ")
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
