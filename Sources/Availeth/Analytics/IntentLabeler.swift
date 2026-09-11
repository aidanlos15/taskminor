import Foundation

/// Names sittings of work by intent, so the Tasks tab reads like a to-do list
/// ("Draft the supplier payment-terms email") rather than a window title
/// ("Claude"). Runs after the Synthesizer on the same 90 s tick, entirely on the
/// local model, and persists one label per span so titles never move.
///
/// For every closed session (same app/site + window title, no gap over five
/// minutes) that has no label yet:
///   • a neighbouring sitting of the same window, named moments ago, lends its
///     label — a refocus is not a new task;
///   • an informative window title is passed through as the title, no model call;
///   • a bare or generic title with captured detail (screen narratives, minute
///     notes) is put to the model, which names the work and says whether it is
///     one of this unit's existing tasks;
///   • a generic title with nothing captured gets the plain unit name — never a guess.
final class IntentLabeler {
    struct Config {
        /// Model calls per tick — keeps frame narration and minute synthesis responsive.
        var maxModelCallsPerRun = 6
        var gapSeconds: TimeInterval = 5 * 60
        /// A session whose last span ended more recently than this may still grow.
        /// Never shorter than the gap, or a sitting could be named in two halves.
        var graceSeconds: TimeInterval = 5 * 60
        var lookback: TimeInterval = 14 * 86400
        var minSessionSeconds: TimeInterval = 30
        var maxExistingTitles = 12
        var maxNarratives = 8
        var maxMinutes = 5
        var batchLimit = 400
        init() {}
    }

    /// One sitting: same unit and cleaned title, spans time-sorted.
    struct Session: Equatable {
        var unit: String
        var cleanTitle: String
        var spans: [ActivitySpan]
        var start: Date { spans.first?.start ?? .distantPast }
        var end: Date { spans.map(\.end).max() ?? .distantPast }
        var duration: TimeInterval { spans.reduce(0) { $0 + $1.duration } }
        var titleKey: String { LabelKey.canonKey(cleanTitle) }
        var sessionKey: String { unit + "\u{1F}" + String(spans.first?.id ?? 0) }
    }

    struct Evidence {
        var narratives: [SceneNarrative]
        var minutes: [MinuteSummary]
        var isEmpty: Bool { narratives.isEmpty && minutes.isEmpty }
    }

    private let store: Store
    private let interpreter: SceneInterpreter
    private let config: Config
    private(set) var isRunning = false
    /// Change detection: skip the scan when no span landed and nothing was left over.
    private var lastMaxSpanID: Int64 = -1
    private var leftWork = true
    /// Model calls made over the labeler's lifetime (tests count them).
    private(set) var modelCalls = 0

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

        let maxID = store.maxSpanID(demo: false)
        if maxID == lastMaxSpanID && !leftWork { return }
        lastMaxSpanID = maxID
        leftWork = false

        let spans = store.unlabelledSpans(from: now.addingTimeInterval(-config.lookback), before: now, demo: false, limit: config.batchLimit)
        guard !spans.isEmpty else { return }
        if spans.count >= config.batchLimit { leftWork = true }

        var calls = 0
        var available: Bool?
        for session in Self.sessionise(spans, gap: config.gapSeconds) {
            // Still growing — name it next tick.
            if session.end > now.addingTimeInterval(-config.graceSeconds) { leftWork = true; continue }

            // 1. A sitting of the same window named moments before (or just after —
            //    a batch boundary can cut a sitting in two). A neighbour that only
            //    got the fallback name is joined, not copied: this half may carry
            //    the evidence that names them both.
            let neighbour = store.neighbourLabel(unit: session.unit, titleKey: session.titleKey,
                                                 sessionStart: session.start, sessionEnd: session.end,
                                                 gap: config.gapSeconds, demo: false)
            if let n = neighbour, n.source != .fallback {
                write(session, intent: n.intent, canon: n.canon, source: n.source, model: n.model, sessionKey: n.sessionKey, now: now)
                continue
            }
            // 2. The window title already says what the work was.
            if !LabelKey.isUninformative(unit: session.unit, cleanTitle: session.cleanTitle) {
                write(session, intent: session.cleanTitle, canon: session.cleanTitle, source: .title, now: now)
                continue
            }
            // 3. A glance, not a task.
            if session.duration < config.minSessionSeconds {
                write(session, intent: session.unit, canon: session.unit, source: .fallback, sessionKey: neighbour?.sessionKey, now: now)
                continue
            }
            // 4. Nothing was captured — nothing to name it from. Honest fallback.
            let evidence = evidence(for: session)
            if evidence.isEmpty {
                write(session, intent: session.unit, canon: session.unit, source: .fallback, sessionKey: neighbour?.sessionKey, now: now)
                continue
            }
            // 5. Ask the local model.
            guard calls < config.maxModelCallsPerRun else { leftWork = true; continue }
            if available == nil { available = await interpreter.isAvailable() }
            guard available == true else { leftWork = true; continue }

            let existing = store.canonTitles(unit: session.unit, demo: false, limit: config.maxExistingTitles)
            let prompt = Self.prompt(session: session, evidence: evidence, existing: existing)
            calls += 1
            modelCalls += 1
            guard let raw = await interpreter.summarize(prompt: prompt, maxTokens: 60) else {
                // Transport failure (busy/offline): leave the session for the
                // next tick rather than settling it on a failure.
                leftWork = true
                available = false
                continue
            }
            if let parsed = Self.parse(raw, existing: existing, unit: session.unit) {
                let canon = parsed.matched ?? LabelKey.merge(parsed.title, into: existing)
                write(session, intent: parsed.title, canon: canon, source: .model, model: interpreter.displayName, sessionKey: neighbour?.sessionKey, now: now)
                if let n = neighbour {
                    // The other half of this sitting only had the fallback name.
                    store.relabelSession(sessionKey: n.sessionKey, intent: parsed.title, canon: canon, source: .model, model: interpreter.displayName)
                }
            } else {
                // The model replied but said nothing usable: settle on the
                // unit name so the session is never re-asked, never invented.
                write(session, intent: session.unit, canon: session.unit, source: .fallback, sessionKey: neighbour?.sessionKey, now: now)
            }
        }
    }

    private func write(_ s: Session, intent: String, canon: String, source: LabelSource, model: String = "", sessionKey: String? = nil, now: Date) {
        let rows = s.spans.map {
            SpanLabel(spanID: $0.id, sessionKey: sessionKey ?? s.sessionKey, unit: s.unit, titleKey: s.titleKey,
                      intent: intent, canon: canon, source: source, model: model, created: now, isDemo: $0.isDemo)
        }
        store.insertSpanLabels(rows)
    }

    // MARK: - Sessions

    /// Groups spans by (unit, cleaned title), splits each group on gaps, and
    /// returns the sittings newest first — what the user is looking at gets named first.
    static func sessionise(_ spans: [ActivitySpan], gap: TimeInterval) -> [Session] {
        struct Key: Hashable { var unit: String; var titleKey: String }
        var byKey: [Key: (unit: String, title: String, spans: [ActivitySpan])] = [:]
        for s in spans {
            let unit = WorkflowUnit.label(app: s.appName, title: s.windowTitle)
            let title = LabelKey.cleanTitle(s.windowTitle, appName: s.appName)
            let k = Key(unit: unit, titleKey: LabelKey.canonKey(title))
            var g = byKey[k] ?? (unit, title, [])
            g.spans.append(s)
            byKey[k] = g
        }
        var out: [Session] = []
        for g in byKey.values {
            for run in Analytics.splitSpansByGap(g.spans.sorted { $0.start < $1.start }, gap: gap) {
                out.append(Session(unit: g.unit, cleanTitle: g.title, spans: run))
            }
        }
        return out.sorted { $0.start != $1.start ? $0.start > $1.start : $0.sessionKey < $1.sessionKey }
    }

    // MARK: - Evidence

    /// What was captured while the session was on screen: narratives of the same
    /// unit inside the session's window (±30 s), and the minute notes that
    /// mention it. Narratives are pruned after a day; minute notes are the
    /// durable record for anything older.
    private func evidence(for s: Session) -> Evidence {
        let from = s.start.addingTimeInterval(-30), to = s.end.addingTimeInterval(30)
        let narratives = store.narratives(from: from, to: to, demo: false)
            .filter { WorkflowUnit.label(app: $0.appName, title: $0.windowTitle) == s.unit }
            .sorted { $0.timestamp < $1.timestamp }
        let minutes = store.minuteSummaries(from: s.start.addingTimeInterval(-60), to: s.end.addingTimeInterval(60), demo: false)
            .filter { !$0.text.isEmpty && $0.text != "Away from keyboard" && $0.taskID != -1 }
            .sorted { $0.minuteStart < $1.minuteStart }
        // Only minute notes that name this app/site count — another app's
        // notes are not evidence of what happened here.
        let appName = s.spans.first?.appName ?? ""
        let mentioning = minutes.filter {
            $0.apps.localizedCaseInsensitiveContains(s.unit) || (!appName.isEmpty && $0.apps.localizedCaseInsensitiveContains(appName))
        }
        return Evidence(narratives: Self.dedup(narratives), minutes: mentioning)
    }

    private static func dedup(_ ns: [SceneNarrative]) -> [SceneNarrative] {
        var out: [SceneNarrative] = []
        for n in ns where out.last?.text != n.text { out.append(n) }
        return out
    }

    /// `count` items spread evenly across the list (always the first and last).
    static func spread<T>(_ items: [T], _ count: Int) -> [T] {
        guard items.count > count, count > 1 else { return items }
        return (0..<count).map { i in items[Int(round(Double(i) * Double(items.count - 1) / Double(count - 1)))] }
    }

    // MARK: - Prompt

    static func prompt(session s: Session, evidence: Evidence, existing: [String], config: Config = Config(), calendar: Calendar = .current) -> String {
        let clock = DateFormatter()
        clock.calendar = calendar; clock.timeZone = calendar.timeZone; clock.dateFormat = "HH:mm"
        let day = DateFormatter()
        day.calendar = calendar; day.timeZone = calendar.timeZone; day.dateFormat = "EEE d MMM"

        var lines: [String] = []
        lines.append("You are naming one work session so it reads like an item on a to-do list.")
        lines.append("App: \(s.unit)")
        if LabelKey.canonKey(s.cleanTitle) != LabelKey.canonKey(s.unit), !s.cleanTitle.hasPrefix("General ") {
            lines.append("Window: \(s.cleanTitle)")
        }
        lines.append("When: \(day.string(from: s.start)), \(clock.string(from: s.start))\u{2013}\(clock.string(from: s.end)) (\(max(1, Int(s.duration / 60))) min, \(s.spans.count) visit\(s.spans.count == 1 ? "" : "s"))")
        let keys = s.spans.reduce(0) { $0 + $1.keystrokes }, clicks = s.spans.reduce(0) { $0 + $1.clicks }
        if keys + clicks > 0 {
            var t = "Typing: \(keys) keystrokes, \(clicks) clicks."
            let shortcuts = s.spans.map(\.shortcuts).filter { !$0.isEmpty }.joined(separator: ", ")
            let fields = s.spans.map(\.fields).filter { !$0.isEmpty }.joined(separator: ", ")
            if !shortcuts.isEmpty { t += " Shortcuts: \(String(shortcuts.prefix(120)))." }
            if !fields.isEmpty { t += " Fields: \(String(fields.prefix(120)))." }
            lines.append(t)
        }
        if let doc = s.spans.map(\.documentPath).first(where: { !$0.isEmpty }) {
            lines.append("Document: \((doc as NSString).lastPathComponent)")
        }
        if !evidence.narratives.isEmpty {
            lines.append("")
            lines.append("What was on screen during this session, oldest first:")
            for n in spread(evidence.narratives, config.maxNarratives) {
                lines.append("[\(clock.string(from: n.timestamp))] \(clip(n.text, 350))")
            }
        }
        if !evidence.minutes.isEmpty {
            lines.append("")
            lines.append("Minute notes:")
            for m in spread(evidence.minutes, config.maxMinutes) {
                lines.append("- \(clock.string(from: m.minuteStart)) \(clip(m.text, 220))")
            }
        }
        if !existing.isEmpty {
            lines.append("")
            lines.append("Existing tasks for \(s.unit) (choose one ONLY if this session is the same piece of work):")
            for (i, e) in existing.enumerated() { lines.append("\(i + 1). \(e)") }
        }
        lines.append("")
        lines.append("""
        Rules:
        - Say what the person was trying to get done, not what the screen looked like.
        - 3 to 8 words, start with a verb, name the concrete subject (the document, project, customer or question). \
        Examples: "Draft the supplier payment-terms email", "Debug a Swift build error", "Compare AI model capabilities".
        - Use only facts above. No people's names, numbers, amounts, emails or IDs. \
        Never write "the user", "screenshot", "screen", "session" or "\(s.unit)".
        - If the evidence does not show what the work was, leave the title empty.
        Reply with exactly two lines:
        MATCH: <number of the existing task, or 0>
        TITLE: <the title>
        """)
        return lines.joined(separator: "\n")
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count <= n ? t : String(t.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    // MARK: - Parsing

    private static let matchLine = #/^[\s*#]*(?i:match)\s*\**\s*:\s*\**\s*(\d+)?/#
    private static let titleLine = #/^[\s*#]*(?i:title)\s*\**\s*:\s*(.*)$/#
    private static let leadIn = #/^(?i:the\s+(?:user|employee|person)\s+(?:is|was)\s+|user\s+(?:is|was)\s+|they\s+(?:are|were)\s+)/#
    /// Descriptions of the screen, refusals and hedges are not tasks. Anchored
    /// so real titles ("Set up screen recording", "Plan the training session") pass.
    /// Note: Swift's `\b` is a Unicode word boundary, so "I'm" is one word — the
    /// leading pronoun is followed by an explicit space/apostrophe class instead.
    private static let rejected = #/^(?i:(?:the\s+)?(?:screenshot|screen|image|session|user)\b|(?:i|we|sorry|unfortunately|there)(?:[\s'\u{2019}]|$))|\b(?i:the user|shows|displays|depicts|unknown|unclear|insufficient|not enough|enough information|no evidence|cannot|can'?t|unable to|not sure|no title|n\/a)\b/#

    /// The model's reply → (title, matched existing title or nil). nil = unusable.
    /// A reply with no MATCH/TITLE labels at all is read as a bare title; once a
    /// label is present, only the labelled line counts — an empty TITLE stays
    /// empty, whatever explanation follows it.
    static func parse(_ raw: String?, existing: [String], unit: String) -> (title: String, matched: String?)? {
        guard let raw else { return nil }
        var match = 0, title = "", bare = "", sawLabel = false
        for line in StoryFormat.normalise(raw).split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if let m = l.firstMatch(of: matchLine) { sawLabel = true; match = m.1.flatMap { Int($0) } ?? 0 }
            else if let m = l.firstMatch(of: titleLine) { sawLabel = true; title = String(m.1) }
            else if bare.isEmpty, !l.isEmpty, l.split(separator: " ").count <= 12 { bare = l }
        }
        if !sawLabel { title = bare }
        let cleaned = cleanTitle(title, unit: unit)
        if match >= 1, match <= existing.count {
            let canon = existing[match - 1]
            return (title: cleaned ?? canon, matched: canon)
        }
        guard let t = cleaned else { return nil }
        return (title: t, matched: nil)
    }

    /// Scrubs a candidate title; nil when it isn't a task ("the screenshot shows…", the app name, empty).
    static func cleanTitle(_ raw: String, unit: String) -> String? {
        var t = StoryFormat.plain(raw)
        for token in ["[id]", "[amount]", "[email]"] { t = t.replacingOccurrences(of: token, with: "") }
        if let m = t.firstMatch(of: leadIn) { t = String(t[m.range.upperBound...]) }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        while t.hasSuffix(".") || t.hasSuffix(",") { t.removeLast() }
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") { t = String(t.dropFirst().dropLast()) }
        t = t.trimmingCharacters(in: .whitespaces)
        let words = t.split(separator: " ")
        guard words.count >= 2, words.count <= 12,
              LabelKey.canonKey(t) != LabelKey.canonKey(unit),
              t.firstMatch(of: rejected) == nil else { return nil }
        if t.count > 60 {
            var cut = String(t.prefix(60))
            if let sp = cut.lastIndex(of: " ") { cut = String(cut[..<sp]) }
            t = cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-"))
        }
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}
