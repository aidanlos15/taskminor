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
    /// The wall-clock window of that representative run.
    var representativeWindow: DateInterval? = nil
    /// The raw facts behind the automatable read (data moved, fields filled, thinking work).
    var evidence: WorkflowInsighter.Evidence? = nil
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
        let repIndex = occNarr.indices.max { occNarr[$0].count < occNarr[$1].count }
        let moments = repIndex.map { occNarr[$0] } ?? []
        let representativeWindow = repIndex.map { pattern.windows[$0] } ?? pattern.windows.last

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

        let evidence = assessAutomation(pattern: pattern, occSpans: occSpans, narratives: runNarr)
        // The miner scored structure (repetition, consistency, apps). The
        // evidence — data moved between systems, fields filled — is what makes
        // work automatable, so it carries the rest of the score.
        var scored = pattern
        scored.automationScore = finalScore(base: pattern.automationScore, evidence: evidence)

        return WorkflowInsight(
            pattern: scored,
            title: deriveTitle(pattern: pattern, steps: steps),
            whatItIs: deriveWhatItIs(pattern: pattern, moments: moments, steps: steps),
            whatToAutomate: evidence.text,
            automatable: evidence.automatable,
            moments: moments,
            representativeWindow: representativeWindow,
            evidence: evidence,
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
        // One line per moment — its first sentence — so a run reads as a
        // sequence, not a wall of screen descriptions.
        let ordered = dedupConsecutive(moments.map(\.text)
            .filter { !$0.isEmpty && $0 != "Away from keyboard" }
            .map { StoryFormat.sentences(StoryFormat.plain($0)).first ?? $0 })
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
    struct Evidence: Equatable {
        var text: String
        var automatable: Bool
        /// Copy in one system, paste in another, on the runs.
        var crossAppTransfer: Bool
        /// Real field names entered on most runs.
        var consistentFields: [String]
        /// The kind of thinking work the narratives describe, when they do.
        var cognitive: String?
    }

    static func analyzeAutomation(pattern: WorkflowPattern, occSpans: [[ActivitySpan]], narratives: [SceneNarrative]) -> (text: String, automatable: Bool) {
        let e = assessAutomation(pattern: pattern, occSpans: occSpans, narratives: narratives)
        return (e.text, e.automatable)
    }

    /// Evidence on top of the miner's structural score (max 55):
    ///  +30 when data was moved between two systems by copy/paste on the runs,
    ///  +10…15 when the same real fields were filled on most runs,
    ///  and a workflow with no mechanical evidence is capped at 45 — 10 lower
    ///  again when the narratives read as thinking work.
    static func finalScore(base: Int, evidence: Evidence) -> Int {
        var s = Double(base)
        if evidence.crossAppTransfer { s += 30 }
        if !evidence.consistentFields.isEmpty { s += min(15, 8 + Double(evidence.consistentFields.count) * 2) }
        if !evidence.automatable {
            s = min(s, 45)
            if evidence.cognitive != nil { s -= 10 }
        }
        return min(98, max(5, Int(s.rounded())))
    }

    static func assessAutomation(pattern: WorkflowPattern, occSpans: [[ActivitySpan]], narratives: [SceneNarrative]) -> Evidence {
        let allSpans = occSpans.flatMap { $0 }

        // 1. Cross-system data transfer: copies in one unit, pastes in a
        //    different one — by chord COUNT, so an incidental ⌘C in the
        //    destination sheet never cancels thirty copies from the source.
        let transfer = crossAppTransfer(allSpans)
        let copyApp = transfer?.from, pasteApp = transfer?.to
        let crossAppTransfer = transfer != nil

        // 2. Consistent structured field entry: real field names entered on most
        //    runs (not UI hint text, and not a form the user touched only once).
        let consistentFields = consistentFieldNames(occSpans)

        // Fields alone count only when there is a real form: two or more
        // consistent fields, or one committed with Tab/Enter on the runs.
        let commits = allSpans.reduce(0) { acc, s in
            let c = chordCounts(s.shortcuts); return acc + (c["Tab"] ?? 0) + (c["↵"] ?? 0)
        }
        let formEntry = consistentFields.count >= 2 || (consistentFields.count == 1 && commits >= pattern.occurrences)
        let mechanical = crossAppTransfer || formEntry

        // 3. Cognitive signal from the narratives — reading, analysing, writing.
        let cognitive = dominantCognitiveKind(narratives)

        var parts: [String] = []

        if mechanical {
            if let copyApp, let pasteApp {
                parts.append("You move data from \(copyApp) into \(pasteApp) by hand each time — an automation could transfer it directly via their APIs, removing the copy-and-paste.")
            }
            if formEntry {
                parts.append("The same fields are entered on most runs (\(consistentFields.joined(separator: ", "))) — these could be auto-filled from the source instead of typed.")
            }
            parts.append("At the observed rate that's about \(Format.hours(pattern.estimatedHoursPerYear)) a year.")
            return Evidence(text: parts.joined(separator: " "), automatable: true,
                            crossAppTransfer: crossAppTransfer, consistentFields: formEntry ? consistentFields : [], cognitive: cognitive)
        }

        // No mechanical evidence → be honest: this is thinking work, not a task.
        if let cognitive {
            return Evidence(text: "This looks mostly like \(cognitive) — the kind of judgement and thinking work a person does, not a mechanical task. It isn't a strong automation candidate. (An AI can *assist* here, but it can't run it unattended.)",
                            automatable: false, crossAppTransfer: false, consistentFields: [], cognitive: cognitive)
        }
        let apps = distinct(pattern.apps.map(shortApp))
        return Evidence(text: "You repeat this move between \(apps.joined(separator: ", ")), but there's no sign of data being moved or forms being filled — so it looks like navigation or reading rather than a task to automate. Turn on Screen capture (Privacy tab) to capture more detail, or treat this as low-priority.",
                        automatable: false, crossAppTransfer: false, consistentFields: [], cognitive: nil)
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
        // A search/find/filter box is navigation, not data entry.
        if s.range(of: #"\[(search|filter)\]"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        s = s.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression) // drop [class]
        if s.range(of: #"(?i)\b(search|find|filter|look ?up)\b"#, options: .regularExpression) != nil { return nil }
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

    /// "⌘C×12, ⌘V×12, Tab×40" → ["⌘C": 12, "⌘V": 12, "Tab": 40]. A chord with
    /// no count is one press. Exact tokens, so ⇧⌘C is not ⌘C.
    static func chordCounts(_ shortcuts: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for raw in shortcuts.split(separator: ",") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if let x = t.range(of: "×") {
                out[String(t[..<x.lowerBound]), default: 0] += Int(t[x.upperBound...]) ?? 1
            } else {
                out[t, default: 0] += 1
            }
        }
        return out
    }

    /// The (source, destination) pair with the most copies in one unit and
    /// pastes in a different one, or nil when no such pair carries real
    /// weight. Names the transfer "Excel → NetSuite", never "Chrome → Chrome".
    static func crossAppTransfer(_ spans: [ActivitySpan]) -> (from: String, to: String)? {
        var copies: [String: Int] = [:], pastes: [String: Int] = [:]
        for s in spans {
            let unit = WorkflowUnit.label(app: s.appName, title: s.windowTitle)
            let c = chordCounts(s.shortcuts)
            if let n = c["⌘C"], n > 0 { copies[unit, default: 0] += n }
            if let n = c["⌘V"], n > 0 { pastes[unit, default: 0] += n }
        }
        var best: (from: String, to: String, weight: Int)?
        for (from, c) in copies {
            for (to, p) in pastes where to != from {
                // Both ends must be habitual (at least three chords), and the
                // pair must be the dominant direction, not a stray.
                guard c >= 3, p >= 3 else { continue }
                let w = min(c, p)
                if w > (best?.weight ?? 0) || (w == (best?.weight ?? 0) && (from, to) < (best!.from, best!.to)) {
                    best = (from, to, w)
                }
            }
        }
        guard let best else { return nil }
        // A same-unit copy/paste that outweighs the cross-unit pair (a sheet
        // rearranged within itself) is not a transfer between systems.
        let within = max(copies.map { min($0.value, pastes[$0.key] ?? 0) }.max() ?? 0, 0)
        return within > best.weight * 2 ? nil : (best.from, best.to)
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
