import Foundation

/// Asks the local model what to DO about each recurring piece of work — and,
/// in particular, whether the right answer is a small custom app: a process
/// run by hand on generic tools (a rota kept in a spreadsheet with
/// availability collected over messages, a booking list, a tracker, quotes
/// built by hand) because no purpose-built tool exists. Runs after the
/// labeler on the same tick; judgements are persisted and re-made only when
/// the evidence grows.
final class OpportunityAssessor {
    struct Config {
        var maxModelCallsPerRun = 3
        var lookback: TimeInterval = 14 * 86400
        /// Tasks shorter than this aren't worth a judgement.
        var minTaskSeconds: TimeInterval = 4 * 60
        /// Re-assess a workflow once it has this many more occurrences.
        var reassessAfterExtraOccurrences = 3
        var maxLines = 10
        init() {}
    }

    private let store: Store
    private let interpreter: SceneInterpreter
    private let config: Config
    private(set) var isRunning = false
    private(set) var modelCalls = 0
    /// Items whose reply was unusable (or never came) wait before being asked
    /// again — doubling up to a day — so one stubborn item can't hog the budget.
    private var backoff: [String: (attempts: Int, next: Date)] = [:]
    /// Change detection: no new spans or tasks since the last run → nothing to judge.
    private var lastMaxSpanID: Int64 = -1
    private var lastTaskCount = -1

    private func eligible(_ key: String, now: Date) -> Bool { (backoff[key]?.next ?? .distantPast) <= now }
    private func failed(_ key: String, now: Date) {
        let n = (backoff[key]?.attempts ?? 0) + 1
        backoff[key] = (n, now.addingTimeInterval(min(86400, 600 * pow(2, Double(n - 1)))))
    }

    init(store: Store, interpreter: SceneInterpreter, config: Config = Config()) {
        self.store = store
        self.interpreter = interpreter
        self.config = config
    }

    // MARK: - Orchestration

    func run(now: Date = Date()) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let from = now.addingTimeInterval(-config.lookback), to = now.addingTimeInterval(60)
        // Nothing new since last time and nothing waiting on a backoff → skip the mine.
        let maxID = store.maxSpanID(demo: false)
        let tasks = store.taskSummaries(from: from, to: to, demo: false)
        let anyBackoffDue = backoff.contains { $0.value.next <= now }
        if maxID == lastMaxSpanID, tasks.count == lastTaskCount, !anyBackoffDue { return }
        lastMaxSpanID = maxID; lastTaskCount = tasks.count

        var calls = 0
        var available: Bool?
        let existing = store.opportunities(demo: false)

        // Workflows first: the strongest signal, and the fewest of them.
        let spans = store.spans(from: from, to: to, demo: false)
        let patterns = PatternMiner.mine(spans: spans)
        // A judgement whose chain no longer exists is stale; drop it.
        for key in existing.keys where key.hasPrefix("wf:") && !patterns.contains(where: { "wf:" + $0.id == key }) {
            store.deleteOpportunity(key: key)
        }
        for pattern in patterns {
            let key = "wf:" + pattern.id
            if let done = existing[key], pattern.occurrences >= done.evidence, pattern.occurrences < done.evidence + config.reassessAfterExtraOccurrences { continue }
            guard eligible(key, now: now) else { continue }
            guard calls < config.maxModelCallsPerRun else { return }
            if available == nil { available = await interpreter.isAvailable() }
            guard available == true else { return }
            let insight = WorkflowInsighter.build(pattern, store: store, demo: false)
            let prompt = Self.prompt(workflow: insight, config: config)
            calls += 1; modelCalls += 1
            guard let raw = await interpreter.summarize(prompt: prompt, maxTokens: 180) else { failed(key, now: now); return }
            if var o = Self.parse(raw, key: key, evidence: pattern.occurrences, model: interpreter.displayName, now: now) {
                let steps = insight.steps.map { "\($0.app) \($0.detail)" }.joined(separator: " ")
                let hint = Self.looksLikeCustomAppCandidate(units: pattern.apps, titles: insight.title + " " + steps, text: insight.moments.map(\.text).joined(separator: " "))
                Self.apply(guard: Self.guarded(o.kind, mechanical: insight.automatable, hint: hint,
                                               cognitive: WorkflowInsighter.dominantCognitiveKind(insight.moments) != nil), to: &o)
                store.upsertOpportunity(o)
                backoff[key] = nil
            } else {
                failed(key, now: now)
            }
        }

        // Then tasks (the Story), which see messaging and everything else.
        for task in tasks where task.duration >= config.minTaskSeconds {
            let key = "task:\(task.id)"
            if existing[key] != nil { continue }
            guard eligible(key, now: now) else { continue }
            guard calls < config.maxModelCallsPerRun else { return }
            if available == nil { available = await interpreter.isAvailable() }
            guard available == true else { return }
            let minutes = store.minutesForTask(task.id)
            let prompt = Self.prompt(task: task, minutes: minutes, config: config)
            calls += 1; modelCalls += 1
            guard let raw = await interpreter.summarize(prompt: prompt, maxTokens: 180) else { failed(key, now: now); return }
            if var o = Self.parse(raw, key: key, evidence: task.minuteCount, model: interpreter.displayName, now: now) {
                let units = task.apps.split(separator: ",").map { WorkflowUnit.shortApp($0.trimmingCharacters(in: .whitespaces)) }
                let hint = Self.looksLikeCustomAppCandidate(units: units, titles: task.title, text: task.text + " " + minutes.map(\.text).joined(separator: " "))
                let taskSpans = store.spans(from: task.start, to: task.end, demo: false)
                let asNarratives = minutes.filter { !$0.text.isEmpty }.map { SceneNarrative(timestamp: $0.minuteStart, appName: "", windowTitle: "", text: $0.text) }
                Self.apply(guard: Self.guarded(o.kind, mechanical: Self.mechanicalEvidence(task: task, minutes: minutes, spans: taskSpans), hint: hint,
                                               cognitive: WorkflowInsighter.dominantCognitiveKind(asNarratives) != nil), to: &o)
                store.upsertOpportunity(o)
                backoff[key] = nil
            } else {
                failed(key, now: now)
            }
        }
    }

    // MARK: - Guarding the verdict

    /// A 7B model leans towards INTEGRATION because it sounds useful. The
    /// verdict is held to the evidence: INTEGRATION needs data actually moved
    /// or fields actually filled; APP needs that or the hand-run-process
    /// shape; judgement work (cognitive) can be neither.
    static func guarded(_ kind: Opportunity.Kind, mechanical: Bool, hint: Bool, cognitive: Bool) -> Opportunity.Kind {
        switch kind {
        case .integration:
            if mechanical { return .integration }
            return cognitive ? .manual : .streamline
        case .customApp:
            // The hand-run-process shape carries APP only when the work isn't judgement.
            if mechanical || (hint && !cognitive) { return .customApp }
            return cognitive ? .manual : .streamline
        case .streamline:
            return cognitive ? .manual : .streamline
        case .manual:
            return .manual
        }
    }

    /// A downgraded verdict says so, rather than keeping a headline that
    /// contradicts its pill.
    static func apply(guard kind: Opportunity.Kind, to o: inout Opportunity) {
        guard kind != o.kind else { return }
        let suggested = o.kind
        o.kind = kind
        o.headline = kind == .manual ? "Nothing to build \u{2014} this is judgement work" : kind.title
        o.rationale = "Held to the evidence: the model suggested \(suggested.label.lowercased()), but nothing captured shows data being moved between systems or a process kept by hand."
        o.confidence = "low"
    }

    /// A task moved data between two systems (copies in one app, pastes in
    /// another — from its spans), filled real fields consistently, or carries
    /// the Story's own High read.
    static func mechanicalEvidence(task: TaskSummary, minutes: [MinuteSummary], spans: [ActivitySpan] = []) -> Bool {
        if task.automatable.hasPrefix("High") { return true }
        if WorkflowInsighter.crossAppTransfer(spans) != nil { return true }
        let fields = minutes.flatMap { $0.fields.split(separator: ",") }.compactMap { WorkflowInsighter.cleanFieldName(String($0)) }
        return Set(fields).count >= 2 && task.automatable.hasPrefix("Medium")
    }

    // MARK: - Heuristic hint

    /// Generic tools people run processes on when nothing purpose-built exists.
    static let genericTools: Set<String> = [
        "Excel", "Numbers", "Google Sheets", "Sheets", "Notes", "Word", "Google Docs", "Docs", "Pages", "TextEdit",
        "Mail", "Gmail", "Outlook", "Messages", "WhatsApp", "Slack", "Teams", "Notion", "Reminders", "Calendar", "Google Calendar",
    ]
    /// Things people keep by hand that a small app would keep for them.
    static let artefactWords: [String] = [
        "rota", "roster", "schedule", "shift", "availability", "timesheet", "tracker", "register", "checklist",
        "booking", "reservation", "inventory", "stock", "sign-up", "signup", "attendance", "quote", "order form",
        "holiday", "leave request", "onboarding", "expenses", "log book", "logbook", "waiting list", "waitlist",
    ]

    /// Tools a process's RECORD lives in (a spreadsheet, notes, a doc) — the
    /// signature of a hand-kept process, as opposed to email/calendar alone.
    static let recordTools: Set<String> = ["Excel", "Numbers", "Google Sheets", "Sheets", "Notes", "Word", "Google Docs", "Docs", "Pages", "TextEdit", "Notion"]

    /// True when the evidence looks like a hand-run process on generic tools —
    /// offered to the model as a hint, never as the verdict. Artefact words
    /// count on word boundaries; one hit in a window title or step label is
    /// enough, free narrative needs two distinct words; and the record must
    /// live in a spreadsheet/notes/doc, not just an inbox.
    static func looksLikeCustomAppCandidate(units: [String], titles: String, text: String) -> Bool {
        guard !units.isEmpty else { return false }
        let short = units.map { WorkflowUnit.shortApp($0) }
        let generic = Double(short.filter { genericTools.contains($0) }.count) / Double(short.count)
        guard generic >= 0.6, short.contains(where: { recordTools.contains($0) }) else { return false }
        func hits(_ s: String) -> Set<String> {
            let lower = s.lowercased()
            return Set(artefactWords.filter { w in lower.range(of: "\\b" + NSRegularExpression.escapedPattern(for: w) + "\\b", options: .regularExpression) != nil })
        }
        return !hits(titles).isEmpty || hits(text).count >= 2
    }

    /// Back-compatible form used by tests: titles and text together.
    static func looksLikeCustomAppCandidate(units: [String], text: String) -> Bool {
        looksLikeCustomAppCandidate(units: units, titles: text, text: "")
    }

    // MARK: - Prompts

    private static let rules = """
        Decide ONE of these, and be strict \u{2014} MANUAL is the answer unless the evidence clearly shows otherwise:
        MANUAL \u{2014} the default. Reading, writing, thinking, talking to an AI assistant, researching, configuring settings, or a one-off. A person has to do it.
        INTEGRATION \u{2014} ONLY if the evidence shows the same data being copied, pasted or re-keyed between two different systems on every run (copy in one app, paste or type into another; the same fields filled each time). An automation could move that data.
        APP \u{2014} ONLY if a recurring business process is being run by hand on generic tools \u{2014} a spreadsheet, notes, email or messages standing in for software that doesn't exist: keeping a schedule or rota and collecting people's answers one at a time, maintaining a booking list, a tracker, a register, a checklist, building quotes or orders by hand. A small purpose-built app would replace the whole process.
        STREAMLINE \u{2014} a recurring chore that is small: a template, a form or a simpler process would do. Not worth building software.
        Use only the evidence above; do not assume steps you cannot see. Write BUILD in your own words, specific to this work. No people's names, numbers, amounts or IDs.
        Reply with exactly these lines:
        KIND: INTEGRATION | APP | STREAMLINE | MANUAL
        BUILD: <one line: what to build or automate for THIS work; "Nothing" for MANUAL>
        WHY: <one or two sentences that point at the evidence>
        DATA: <the things the process is about, comma-separated>
        CONFIDENCE: low | medium | high
        """

    static func prompt(workflow w: WorkflowInsight, config: Config = Config()) -> String {
        let p = w.pattern
        var lines = ["You advise a business on what to do about one recurring piece of work."]
        lines.append("Workflow: \(w.title)")
        lines.append("Apps, in order: \(p.apps.joined(separator: " \u{2192} ")); repeated \(p.occurrences) times; a run takes about \(Format.preciseDuration(p.medianDuration)).")
        let steps = w.steps.filter { !$0.detail.isEmpty }.map { "\($0.app): \($0.detail)" }
        if !steps.isEmpty { lines.append("Windows: " + steps.prefix(6).joined(separator: " | ")) }
        let moments = IntentLabeler.spread(w.moments.map(\.text).filter { !$0.isEmpty }, config.maxLines)
        if !moments.isEmpty {
            lines.append("What was on screen during one run:")
            lines += moments.map { "- " + clip($0, 300) }
        }
        // Neutral facts only — never the UI's own verdict sentence.
        if let e = w.evidence {
            var facts: [String] = []
            if e.crossAppTransfer { facts.append("data was copied in one app and pasted in another on these runs") }
            if !e.consistentFields.isEmpty { facts.append("the same fields were filled on most runs: \(e.consistentFields.joined(separator: ", "))") }
            if let c = e.cognitive { facts.append("the screen descriptions read mostly as \(c)") }
            if facts.isEmpty { facts.append("no copy/paste between apps and no consistent form fields were seen") }
            lines.append("Observed: " + facts.joined(separator: "; ") + ".")
        }
        if looksLikeCustomAppCandidate(units: p.apps, titles: w.title + " " + steps.joined(separator: " "), text: moments.joined(separator: " ")) {
            lines.append("Hint: this looks like a process kept by hand on generic tools; consider APP.")
        }
        lines.append("")
        lines.append(rules)
        return lines.joined(separator: "\n")
    }

    static func prompt(task t: TaskSummary, minutes: [MinuteSummary], config: Config = Config()) -> String {
        var lines = ["You advise a business on what to do about one piece of work an employee did."]
        lines.append("Task: \(StoryFormat.plain(t.title))")
        lines.append("Apps: \(t.apps); it took \(Format.duration(t.duration)).")
        lines.append("Story: " + clip(StoryFormat.plain(t.text).replacingOccurrences(of: "\n", with: " "), 700))
        let notes = IntentLabeler.spread(minutes.map(\.text).filter { !$0.isEmpty && $0 != "Away from keyboard" }, config.maxLines)
        if !notes.isEmpty {
            lines.append("Minute notes:")
            lines += notes.map { "- " + clip(StoryFormat.plain($0), 220) }
        }
        let fields = minutes.map(\.fields).filter { !$0.isEmpty }.joined(separator: ", ")
        if !fields.isEmpty { lines.append("Fields typed into: " + clip(fields, 200)) }
        let units = t.apps.split(separator: ",").map { WorkflowUnit.shortApp($0.trimmingCharacters(in: .whitespaces)) }
        if looksLikeCustomAppCandidate(units: units, titles: t.title, text: t.text + " " + notes.joined(separator: " ")) {
            lines.append("Hint: this looks like a process kept by hand on generic tools; consider APP.")
        }
        lines.append("")
        lines.append(rules)
        return lines.joined(separator: "\n")
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count <= n ? t : String(t.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    // MARK: - Parsing

    private static let line = #/^[\s*#\-\u{2022}\d.)]*(?i:(kind|build|why|data|confidence))\s*\**\s*[:\u{2014}\-]\s*(.*)$/#

    /// The model's reply → an Opportunity, or nil when it gave no usable KIND.
    static func parse(_ raw: String?, key: String, evidence: Int, model: String, now: Date = Date()) -> Opportunity? {
        guard let raw else { return nil }
        var fields: [String: String] = [:]
        var last: String?
        for l in StoryFormat.normalise(raw).split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let m = l.firstMatch(of: line) {
                last = String(m.1).lowercased()
                fields[last!] = String(m.2)
            } else if let last, !l.isEmpty, last == "why" {
                fields[last, default: ""] += " " + l
            }
        }
        let kindWord = StoryFormat.plain(fields["kind"] ?? "").uppercased()
        // An echoed template ("INTEGRATION | APP | …") is not an answer.
        let named = ["INTEGRATION", "APP", "STREAMLINE", "MANUAL"].filter { kindWord.contains($0) }
        guard named.count == 1, !kindWord.contains("|") else { return nil }
        let kind: Opportunity.Kind
        switch named[0] {
        case "INTEGRATION": kind = .integration
        case "APP": kind = .customApp
        case "STREAMLINE": kind = .streamline
        default: kind = .manual
        }
        var headline = StoryFormat.plain(fields["build"] ?? "")
        for token in ["[id]", "[amount]", "[email]"] { headline = headline.replacingOccurrences(of: token, with: "") }
        headline = headline.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        while headline.hasSuffix(".") { headline.removeLast() }
        if headline.count > 120 { headline = String(headline.prefix(119)) + "\u{2026}" }
        if headline.isEmpty { headline = kind.title }
        let why = StoryFormat.plain(fields["why"] ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let entities = (fields["data"] ?? "").split(separator: ",").map { StoryFormat.plain(String($0)).lowercased() }
            .filter { !$0.isEmpty && $0.count <= 30 }.prefix(6)
        let conf = StoryFormat.plain(fields["confidence"] ?? "").lowercased()
        let confidence = ["low", "medium", "high"].first { conf.hasPrefix($0) } ?? "medium"
        return Opportunity(key: key, kind: kind, headline: headline.prefix(1).uppercased() + headline.dropFirst(),
                           rationale: String(why.prefix(400)), entities: Array(entities), confidence: confidence,
                           model: model, created: now, evidence: evidence)
    }
}
