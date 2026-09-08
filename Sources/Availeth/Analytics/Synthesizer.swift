import Foundation

/// Turns the raw signal streams into the hierarchical story:
///   raw moments  →  minute summaries  →  task summaries (with an automatable read)
///
/// It fuses ALL signals — scene narratives, apps/tabs, keystroke/click counts,
/// shortcuts, and fields — and is idle-aware: minutes the user was away are
/// labeled, never described as work. All synthesis runs on the LOCAL model.
final class Synthesizer {

    struct Config {
        var maxMinutesPerRun = 8
        var taskGapSeconds: TimeInterval = 5 * 60
        var maxTaskMinutes = 10
        /// Don't close a task whose last minute is newer than this (it may grow).
        var taskGraceSeconds: TimeInterval = 120
        /// A minute counts as "away" if idle covered at least this fraction of it.
        var idleFractionForAway = 0.6
        init() {}
    }

    private let store: Store
    private let interpreter: SceneInterpreter
    private let config: Config
    /// On first run (no prior summaries) only look back this far, so launching
    /// after days of captured spans doesn't summarize ancient history.
    private let firstRunLookback: TimeInterval = 2 * 3600

    private(set) var isRunning = false

    init(store: Store, interpreter: SceneInterpreter, config: Config = Config()) {
        self.store = store
        self.interpreter = interpreter
        self.config = config
    }

    // MARK: - Orchestration (live data)

    /// Synthesizes any complete minutes since the last run, then groups closed
    /// runs of minutes into tasks. Safe to call repeatedly; no-op only if already
    /// busy.
    ///
    /// It runs with or without a local model. `summarize` sends no image, so the
    /// story layer needs the TEXT model, not the vision one. With no model at all
    /// every minute still gets a deterministic line built from the captured
    /// signals, because writing nothing leaves the user staring at an empty tab
    /// with no way to tell that anything is wrong.
    func run(now: Date = Date()) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let modelReady = await interpreter.isTextAvailable()
        await synthesizeMinutes(now: now, modelReady: modelReady)
        await groupTasks(now: now, modelReady: modelReady)
    }

    private func synthesizeMinutes(now: Date, modelReady: Bool) async {
        let currentMinute = Self.floorToMinute(now)
        // Resume from the durable store, not a separate watermark that could
        // rewind on a crash. First run: only the recent window.
        let resumeFrom = store.latestMinuteStart(demo: false)?.addingTimeInterval(60)
            ?? Self.floorToMinute(now.addingTimeInterval(-firstRunLookback))
        var minute = Self.floorToMinute(resumeFrom)

        // Skip forward over dead time instead of writing a placeholder row for
        // every empty minute. On a fresh install the resume point is two hours
        // back, and at 8 minutes a run that is about 22 minutes of walking
        // through nothing before the first real minute is reached. Jump straight
        // to the first captured activity.
        if let firstActivity = store.spans(from: minute, to: currentMinute, demo: false).first {
            minute = max(minute, Self.floorToMinute(firstActivity.start))
        } else {
            // Nothing captured in the whole window: settle at the current minute
            // so the next run starts from now rather than two hours ago.
            minute = currentMinute
        }

        var processed = 0

        while minute < currentMinute && processed < config.maxMinutesPerRun {
            let next = minute.addingTimeInterval(60)
            let narratives = store.narratives(from: minute, to: next, demo: false)
            let spans = store.spans(from: minute, to: next, demo: false)
            let idle = store.idleSeconds(from: minute, to: next, demo: false)

            if let ctx = Self.buildMinuteContext(minute: minute, narratives: narratives, spans: spans, idleSeconds: idle, idleFractionForAway: config.idleFractionForAway) {
                if ctx.isAway {
                    // Settled immediately (task_id = -1) so it never groups into a
                    // task and never re-fetches as ungrouped.
                    store.insertMinuteSummary(ctx.summary(text: "Away from keyboard", taskID: -1))
                } else if modelReady, let text = await interpreter.summarize(prompt: ctx.prompt, maxTokens: 180) {
                    store.insertMinuteSummary(ctx.summary(text: text))
                } else {
                    // No model, or the model failed. A line built from the signals
                    // so the minute isn't lost or endlessly retried (the UNIQUE
                    // index prevents dupes).
                    store.insertMinuteSummary(ctx.summary(text: ctx.fallbackText))
                }
            } else {
                // No activity this minute — record a settled placeholder so the
                // resume point advances past it and it's never revisited.
                store.insertMinuteSummary(MinuteSummary(minuteStart: minute, text: "", apps: "", keystrokes: 0, clicks: 0, shortcuts: "", fields: "", sourceCount: 0, taskID: -1, isDemo: false))
            }
            minute = next
            processed += 1
        }
    }

    private func groupTasks(now: Date, modelReady: Bool) async {
        // Away/empty/noise minutes already carry task_id = -1, so the query only
        // returns real ungrouped work minutes.
        let minutes = store.ungroupedMinuteSummaries(demo: false)
        guard !minutes.isEmpty else { return }
        let (closed, _) = Self.groupMinutes(minutes, now: now, config: config)
        for group in closed {
            if Self.isTrivial(group) {
                // Settle isolated noise (a single low-activity minute) without
                // manufacturing a task card for it.
                store.settleMinutes(group.map(\.id))
                continue
            }
            guard let task = await makeTask(from: group, modelReady: modelReady) else { continue }
            store.insertTaskAndLink(task, minuteIDs: group.map(\.id))
        }
    }

    /// A closed group that isn't worth a task card: a single minute with little
    /// activity (a glance at Slack, a stray click).
    static func isTrivial(_ group: [MinuteSummary]) -> Bool {
        guard group.count == 1, let m = group.first else { return false }
        return (m.keystrokes + m.clicks) < 20 && m.sourceCount < 2
    }

    private func makeTask(from group: [MinuteSummary], modelReady: Bool) async -> TaskSummary? {
        guard let first = group.first, let last = group.last else { return nil }
        let apps = Self.mergedApps(group)
        let raw = modelReady
            ? await interpreter.summarize(prompt: Self.taskPrompt(group: group, apps: apps), maxTokens: 400)
            : nil
        let (title, story) = Self.parseTitleAndStory(raw, fallbackApps: apps, fallbackStory: Self.signalStory(group: group, apps: apps))
        let automatable = Self.automatableAssessment(group)
        return TaskSummary(
            start: first.minuteStart,
            end: last.minuteStart.addingTimeInterval(60),
            title: title,
            text: story,
            apps: apps.joined(separator: ", "),
            minuteCount: group.count,
            automatable: automatable
        )
    }

    /// Exact :00.000 minute boundary via epoch math — truncates sub-seconds and
    /// seconds, and (unlike Calendar.date(bySetting:)) never rolls forward into
    /// the current incomplete minute. Minute boundaries are identical across all
    /// real timezones and DST, so no Calendar is needed.
    static func floorToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    // MARK: - Pure minute context

    struct MinuteContext {
        var minute: Date
        var apps: [String]
        var keystrokes: Int
        var clicks: Int
        var shortcuts: String
        var fields: String
        var sceneTexts: [String]
        var sourceCount: Int
        var isAway: Bool

        var prompt: String {
            var lines = [
                "You are documenting ONE minute of an employee's work so a colleague could understand it and judge what could be automated.",
                "Write 2–3 concrete sentences describing exactly what they did this minute. PRESERVE the specific details from the observations below — the exact screens/pages, form fields and their values, and any questions asked of AI tools. Do not generalise or drop specifics.",
                "",
                "Apps/tabs: \(apps.joined(separator: ", "))",
            ]
            if !sceneTexts.isEmpty { lines.append("Screen observations: \(sceneTexts.prefix(8).joined(separator: "; "))") }
            if !shortcuts.isEmpty { lines.append("Shortcuts/keys: \(shortcuts)") }
            if !fields.isEmpty { lines.append("Fields entered: \(fields)") }
            lines.append("Typing: \(keystrokes) keystrokes, \(clicks) clicks.")
            lines.append("\nDetailed account of this minute:")
            return lines.joined(separator: "\n")
        }

        /// What the minute reads as with no model available. Every captured
        /// signal is used, because "Worked in Excel, Chrome." is not worth
        /// storing and tells the user nothing about what could be automated.
        var fallbackText: String {
            if !sceneTexts.isEmpty { return sceneTexts[0] }
            var parts: [String] = []
            let appPart = apps.prefix(3).joined(separator: ", ")
            parts.append(appPart.isEmpty ? "Worked on this Mac." : "Worked in \(appPart).")
            if keystrokes > 0 || clicks > 0 {
                var counts: [String] = []
                if keystrokes > 0 { counts.append("\(keystrokes) keystroke\(keystrokes == 1 ? "" : "s")") }
                if clicks > 0 { counts.append("\(clicks) click\(clicks == 1 ? "" : "s")") }
                parts.append(counts.joined(separator: ", ") + ".")
            }
            if !shortcuts.isEmpty { parts.append("Shortcuts: \(shortcuts).") }
            if !fields.isEmpty { parts.append("Typed into \(fields).") }
            return parts.joined(separator: " ")
        }

        func summary(text: String, taskID: Int64 = 0) -> MinuteSummary {
            MinuteSummary(
                minuteStart: minute, text: text,
                apps: apps.joined(separator: ", "),
                keystrokes: keystrokes, clicks: clicks,
                shortcuts: shortcuts, fields: fields,
                sourceCount: sourceCount, taskID: taskID, isDemo: false
            )
        }
    }

    /// Fuses a minute's raw rows into a context object, or nil if the minute had
    /// no meaningful activity.
    static func buildMinuteContext(minute: Date, narratives: [SceneNarrative], spans: [ActivitySpan], idleSeconds: TimeInterval, idleFractionForAway: Double) -> MinuteContext? {
        let awayDominant = idleSeconds >= 60 * idleFractionForAway
        let hasActivity = !spans.isEmpty || !narratives.isEmpty
        if !hasActivity && awayDominant {
            return MinuteContext(minute: minute, apps: [], keystrokes: 0, clicks: 0, shortcuts: "", fields: "", sceneTexts: [], sourceCount: 0, isAway: true)
        }
        guard hasActivity else { return nil }

        // Distinct apps/tabs, in first-seen order.
        var apps: [String] = []
        var seenApps = Set<String>()
        for span in spans {
            let label = span.windowTitle.isEmpty ? span.appName : "\(span.appName) — \(Analytics.normalizeTitle(span.windowTitle, appName: span.appName))"
            if !seenApps.contains(label) { seenApps.insert(label); apps.append(label) }
        }
        if apps.isEmpty {
            for n in narratives where !n.appName.isEmpty {
                if !seenApps.contains(n.appName) { seenApps.insert(n.appName); apps.append(n.appName) }
            }
        }

        let keystrokes = spans.reduce(0) { $0 + $1.keystrokes }
        let clicks = spans.reduce(0) { $0 + $1.clicks }
        let shortcuts = mergeShortcuts(spans.map(\.shortcuts))
        let fields = mergeFields(spans.map(\.fields))
        let sceneTexts = narratives.map(\.text).filter { !$0.isEmpty }

        // If the whole minute was idle and only stale data lingered, mark away.
        if awayDominant && keystrokes == 0 && clicks == 0 && sceneTexts.isEmpty {
            return MinuteContext(minute: minute, apps: apps, keystrokes: 0, clicks: 0, shortcuts: "", fields: "", sceneTexts: [], sourceCount: 0, isAway: true)
        }
        return MinuteContext(minute: minute, apps: apps, keystrokes: keystrokes, clicks: clicks, shortcuts: shortcuts, fields: fields, sceneTexts: sceneTexts, sourceCount: narratives.count, isAway: false)
    }

    // MARK: - Pure task grouping

    /// Groups consecutive same-task minutes. Returns closed groups (ready to
    /// summarize) and the trailing pending run (too recent to close yet).
    static func groupMinutes(_ minutes: [MinuteSummary], now: Date, config: Config) -> (closed: [[MinuteSummary]], pending: [MinuteSummary]) {
        // Boundary is temporal, NOT app-based: a real workflow deliberately moves
        // through different apps (Mail → Excel → ERP), so splitting on app change
        // would shred exactly the cross-app tasks we most want to see. A task runs
        // until an idle/away gap or the length cap.
        let sorted = minutes.sorted { $0.minuteStart < $1.minuteStart }
        var groups: [[MinuteSummary]] = []
        var current: [MinuteSummary] = []

        for m in sorted {
            if current.isEmpty { current = [m]; continue }
            let prev = current.last!
            let gap = m.minuteStart.timeIntervalSince(prev.minuteStart.addingTimeInterval(60))
            let tooLong = current.count >= config.maxTaskMinutes
            if gap > config.taskGapSeconds || tooLong {
                groups.append(current)
                current = [m]
            } else {
                current.append(m)
            }
        }
        if !current.isEmpty { groups.append(current) }

        // The last group stays pending if its final minute is too recent.
        var closed = groups
        var pending: [MinuteSummary] = []
        if let lastGroup = closed.last, let lastMinute = lastGroup.last {
            let age = now.timeIntervalSince(lastMinute.minuteStart.addingTimeInterval(60))
            if age < config.taskGraceSeconds {
                pending = closed.removeLast()
            }
        }
        return (closed, pending)
    }

    /// A task story built from the captured signals alone, for when no local
    /// model is available. Deliberately factual: how long, which apps, how much
    /// typing, which shortcuts and fields. That is the material an automation
    /// judgement is made from, so the tab is useful before any model is pulled.
    static func signalStory(group: [MinuteSummary], apps: [String]) -> String {
        let minutes = group.count
        let keys = group.reduce(0) { $0 + $1.keystrokes }
        let clicks = group.reduce(0) { $0 + $1.clicks }
        let shortcuts = topTokens(group.map(\.shortcuts), limit: 4)
        let fields = topTokens(group.map(\.fields), limit: 4)

        var parts: [String] = []
        let appPart = apps.isEmpty ? "this Mac" : apps.prefix(4).joined(separator: ", ")
        parts.append("\(minutes) minute\(minutes == 1 ? "" : "s") across \(appPart).")
        if keys > 0 || clicks > 0 {
            var counts: [String] = []
            if keys > 0 { counts.append("\(keys) keystroke\(keys == 1 ? "" : "s")") }
            if clicks > 0 { counts.append("\(clicks) click\(clicks == 1 ? "" : "s")") }
            parts.append(counts.joined(separator: " and ") + ".")
        }
        if !shortcuts.isEmpty { parts.append("Shortcuts used: \(shortcuts.joined(separator: ", ")).") }
        if !fields.isEmpty { parts.append("Fields typed into: \(fields.joined(separator: ", ")).") }
        parts.append("Pull a local text model for a written account of this task.")
        return parts.joined(separator: " ")
    }

    /// Most frequent comma-separated tokens across a set of stored lists.
    /// Shortcut tokens carry their own count ("⌘V×3"); those are merged by key
    /// and the counts summed, so "↵×1" and "↵×3" read as "↵×4" rather than two
    /// separate entries.
    static func topTokens(_ lists: [String], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        var counted: Set<String> = []
        for list in lists {
            for token in list.split(separator: ",") {
                let t = token.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                if let x = t.lastIndex(of: "×"), let n = Int(t[t.index(after: x)...]) {
                    let key = String(t[..<x])
                    counts[key, default: 0] += n
                    counted.insert(key)
                } else {
                    counts[t, default: 0] += 1
                }
            }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { counted.contains($0.key) ? "\($0.key)×\($0.value)" : $0.key }
    }

    static func mergedApps(_ minutes: [MinuteSummary]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for m in minutes {
            // Use the app name (before the em dash) for a compact task-level list.
            for token in m.apps.split(separator: ",") {
                let app = token.trimmingCharacters(in: .whitespaces).components(separatedBy: " — ").first ?? ""
                if !app.isEmpty && !seen.contains(app) { seen.insert(app); out.append(app) }
            }
        }
        return out
    }

    // MARK: - Automatable heuristic (transparent, signal-based)

    /// Reads the fused signals for automation potential. Copy/paste chains across
    /// apps and heavy repeated field entry score high; browsing/reading scores low.
    static func automatableAssessment(_ minutes: [MinuteSummary]) -> String {
        let shortcutsBlob = minutes.map(\.shortcuts).joined(separator: ", ")
        let copyPaste = countOccurrences(of: ["⌘C", "⌘V"], in: shortcutsBlob)
        let tabs = countOccurrences(of: ["Tab"], in: shortcutsBlob)
        let fieldCount = minutes.reduce(0) { $0 + ($1.fields.isEmpty ? 0 : $1.fields.split(separator: ",").count) }
        let apps = mergedApps(minutes).count
        let totalKeys = minutes.reduce(0) { $0 + $1.keystrokes }

        var score = 0
        if copyPaste >= 3 && apps >= 2 { score += 3 } // system-to-system transfer
        else if copyPaste >= 1 { score += 1 }
        if fieldCount >= 3 { score += 2 }
        if tabs >= 4 { score += 1 } // form navigation
        if apps >= 3 { score += 1 }
        if totalKeys > 400 { score += 1 } // heavy manual entry

        let reasons = [
            copyPaste >= 3 && apps >= 2 ? "repeated copy/paste between systems" : nil,
            fieldCount >= 3 ? "structured data entry into fields" : nil,
            tabs >= 4 ? "form/tab navigation" : nil,
            totalKeys > 400 ? "heavy manual typing" : nil,
        ].compactMap { $0 }

        let level = score >= 5 ? "High" : (score >= 2 ? "Medium" : "Low")
        let why = reasons.isEmpty ? (level == "Low" ? "mostly reading/navigation" : "repetitive interactions") : reasons.joined(separator: ", ")
        return "\(level) — \(why)"
    }

    // MARK: - Small helpers

    static func mergeShortcuts(_ blobs: [String]) -> String {
        var counts: [String: Int] = [:]
        for blob in blobs where !blob.isEmpty {
            for token in blob.split(separator: ",") {
                let t = token.trimmingCharacters(in: .whitespaces)
                guard let x = t.range(of: "×") else { counts[t, default: 0] += 1; continue }
                let name = String(t[..<x.lowerBound])
                let n = Int(t[x.upperBound...]) ?? 1
                counts[name, default: 0] += n
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(8).map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
    }

    static func mergeFields(_ blobs: [String]) -> String {
        var seen = Set<String>(), out: [String] = []
        for blob in blobs where !blob.isEmpty {
            for token in blob.split(separator: ",") {
                let f = token.trimmingCharacters(in: .whitespaces)
                if !f.isEmpty && !seen.contains(f) { seen.insert(f); out.append(f) }
            }
        }
        return out.prefix(8).joined(separator: ", ")
    }

    static func taskPrompt(group: [MinuteSummary], apps: [String]) -> String {
        let steps = group.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
        return """
        These are consecutive minutes of one task an employee performed. Write a detailed account (4–6 sentences) of what they actually did, step by step, and the systems and data involved, so a colleague could understand it and decide how to automate it. PRESERVE the concrete specifics from the minutes below — the exact screens, the fields and values, the questions asked. Then give a 3–6 word title.

        Apps involved: \(apps.joined(separator: ", "))
        Minute-by-minute:
        \(steps)

        Reply EXACTLY in this format:
        TITLE: <short title>
        STORY: <4-6 detailed sentences preserving the specifics>
        """
    }

    static func parseTitleAndStory(_ raw: String?, fallbackApps: [String], fallbackStory: String? = nil) -> (title: String, story: String) {
        let fallbackTitle = (fallbackApps.first ?? "Work") + " workflow"
        let fbStory = fallbackStory ?? "Worked across \(fallbackApps.joined(separator: ", "))."
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (fallbackTitle, fbStory)
        }
        var title = "", story = "", sawLabel = false
        for line in raw.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if let r = l.range(of: "TITLE:", options: .caseInsensitive) {
                title = String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces); sawLabel = true
            } else if let r = l.range(of: "STORY:", options: .caseInsensitive) {
                let body = String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                story = story.isEmpty ? body : story + " " + body // append, don't overwrite
                sawLabel = true
            } else if !story.isEmpty {
                story += " " + l // continuation of the story
            }
        }
        if title.isEmpty { title = fallbackTitle }
        if story.isEmpty {
            // Use raw as the story ONLY if it carried no labels to leak; otherwise
            // fall back to the clean signal-derived sentence.
            story = sawLabel ? fbStory : raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (title, story)
    }

    private static func countOccurrences(of needles: [String], in blob: String) -> Int {
        var total = 0
        for token in blob.split(separator: ",") {
            let t = token.trimmingCharacters(in: .whitespaces)
            for needle in needles where t.hasPrefix(needle) {
                if let x = t.range(of: "×") { total += Int(t[x.upperBound...]) ?? 1 } else { total += 1 }
            }
        }
        return total
    }
}
