import Foundation

/// Turns the raw signal streams into the hierarchical story:
///   raw moments  →  minute summaries  →  task summaries (with an automatable read)
///
/// It fuses ALL signals — scene narratives, apps/tabs, keystroke/click counts,
/// shortcuts, and fields — and is idle-aware: minutes the user was away are
/// labeled, never described as work. All synthesis runs on the LOCAL model.
final class Synthesizer {

    struct Config {
        /// Minutes summarised per run. Most minutes are "thin" (windows and
        /// typing only) and never reach the model, so a run of thirty costs a
        /// few seconds; only minutes with fields, moved data or screen notes
        /// wait on the model.
        var maxMinutesPerRun = 60
        var taskGapSeconds: TimeInterval = 5 * 60
        /// Hard ceiling so one unbroken sitting is not a single enormous card.
        /// The model decides where a job ends; this only catches a runaway.
        var maxTaskMinutes = 90
        /// How many times per run the model is asked "same job or new?".
        var maxBoundaryQuestionsPerRun = 8
        /// A task must run this long before a context change can end it.
        var minTaskMinutes = 3
        /// Split when the apps in use turn over completely and stay turned over.
        var splitOnContextChange = true
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
        await synthesizeMinutes(now: now)
        await groupTasks(now: now, modelReady: modelReady)
    }

    private func synthesizeMinutes(now: Date) async {
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

            let transfers = store.transfers(from: minute, to: next, demo: false)
            if let ctx = Self.buildMinuteContext(minute: minute, narratives: narratives, spans: spans, transfers: transfers, idleSeconds: idle, idleFractionForAway: config.idleFractionForAway) {
                if ctx.isAway {
                    // Settled immediately (task_id = -1) so it never groups into a
                    // task and never re-fetches as ungrouped.
                    store.insertMinuteSummary(ctx.summary(text: "Away from keyboard", taskID: -1))
                } else {
                    // A minute is a record, not a story: one true line built
                    // from it (windows, typing, fields, data moved). The model
                    // is never asked about a minute. With a screen narrative
                    // the note from the screen is used; with none, the line is
                    // built from the record, so nothing is invented from a
                    // window title.
                    store.insertMinuteSummary(ctx.summary(text: NarrativeSanitizer.scrub(ctx.fallbackText)))
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
        // With no screen narratives the model is judging window titles alone,
        // and it guesses. The rule is the better answer then.
        let askJudge = Self.mayWriteProse(modelReady: modelReady,
                                          sceneNarratives: sceneNarrativeCount(minutes: minutes))
        // The model decides where a job ends. At each point where the apps in
        // use turn over it is shown the job so far and the minutes that follow
        // and asked whether the same job continues. With no model, or no usable
        // answer, a change that holds for the next minute ends the job.
        var decisions: [Int64: Bool] = [:]
        var grouped = Self.groupMinutes(minutes, now: now, config: config, decisions: decisions, askJudge: askJudge)
        var asked = 0
        while let q = grouped.query, asked < config.maxBoundaryQuestionsPerRun {
            asked += 1
            decisions[q.key] = await judgeBoundary(q) ?? q.ruleSaysNew
            grouped = Self.groupMinutes(minutes, now: now, config: config, decisions: decisions, askJudge: askJudge)
        }
        if grouped.query != nil {
            grouped = Self.groupMinutes(minutes, now: now, config: config, decisions: decisions, askJudge: false)
        }
        let closed = grouped.closed
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

    /// The model may write prose only when the screen was actually described.
    /// From window titles and four counts a small model invents a purpose that
    /// was never there, so with no scene narratives the story stays factual and
    /// the boundary rule decides on its own.
    static func mayWriteProse(modelReady: Bool, sceneNarratives: Int) -> Bool {
        modelReady && sceneNarratives > 0
    }

    /// How many screen narratives sit under this run of minutes.
    private func sceneNarrativeCount(minutes: [MinuteSummary]) -> Int {
        guard let first = minutes.map(\.minuteStart).min(),
              let last = minutes.map(\.minuteStart).max() else { return 0 }
        return store.narratives(from: first, to: last.addingTimeInterval(60), demo: false).count
    }

    /// Asks the model whether the job changed at a turnover point. nil when it
    /// gives no usable answer, so the caller falls back to the rule.
    private func judgeBoundary(_ q: BoundaryQuery) async -> Bool? {
        let prompt = StoryWriter.boundaryPrompt(episode: q.episode, next: q.next)
        guard let raw = await interpreter.summarize(prompt: prompt, maxTokens: 6, stop: ["\n"]) else { return nil }
        return StoryWriter.parseBoundary(raw)
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
        let windowStart = first.minuteStart, windowEnd = last.minuteStart.addingTimeInterval(60)
        let transferList = store.transfers(from: windowStart, to: windowEnd, demo: false)
            .filter { $0.fromUnit != $0.toUnit }
        // What the screen showed during this window. These are the only rows
        // that say what the work actually was, so they feed both the prompt and
        // the plain story - without them a card reads as app names and typing
        // volume and nothing more.
        let taskNarratives = store.narratives(from: windowStart, to: windowEnd, demo: false)
        let record = StoryWriter.taskRecord(minutes: group, transfers: transferList, narratives: taskNarratives)
        // Nothing was captured of the screen for this task, so there is nothing
        // to write from but window titles. Asking a small model for prose there
        // produces invented purpose, so the card stays factual.
        let mayWrite = Self.mayWriteProse(modelReady: modelReady, sceneNarratives: taskNarratives.count)
        let raw = mayWrite
            ? await interpreter.summarize(prompt: StoryWriter.taskPrompt(record), maxTokens: 320, stop: StoryWriter.taskStops)
            : nil
        var (title, story) = StoryWriter.acceptTitleAndStory(raw, record: record)
        story = NarrativeSanitizer.scrub(story)
        if !modelReady { story += " Install the local text model for a written account." }
        story = StoryWriter.capStory(story)
        // How often has this shape of work been seen? A card is judged on the
        // history of its own app set, not on the busyness of one sitting.
        let signature = Set(apps.map { $0.lowercased() })
        let history = store.taskSummaries(from: first.minuteStart.addingTimeInterval(-45 * 86400),
                                          to: last.minuteStart, demo: false)
            .filter { t in
                let other = Set(AppList.appNames(t.apps).map { $0.lowercased() })
                guard !other.isEmpty, !signature.isEmpty else { return false }
                let overlap = Double(signature.intersection(other).count)
                return overlap / Double(max(signature.count, other.count)) >= 0.6
            }
        let occurrences = history.count + 1
        let days = TransferMiner.distinctDays(history.map(\.start) + [first.minuteStart])
        let transfers = transferList.count
        let durations = history.map(\.duration) + [windowEnd.timeIntervalSince(windowStart)]
        let automatable = Self.automatableAssessment(group, occurrences: occurrences, daysObserved: days,
                                                     transfers: transfers, durations: durations)
        return TaskSummary(
            start: first.minuteStart,
            end: last.minuteStart.addingTimeInterval(60),
            title: title,
            text: story,
            // Task level holds app names only, never titles, so a comma is
            // safe here and the Story tab reads it as it always has.
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
        /// The labelled record the model is shown and checked against.
        var record: StoryWriter.MinuteRecord = .init()

        var prompt: String { StoryWriter.minutePrompt(record) }

        /// What the minute reads as with no model, or when the model's entry
        /// failed its checks: a screen note if there is one, else one true
        /// sentence built from the record.
        var fallbackText: String { sceneTexts.first ?? StoryWriter.plainEntry(record) }

        func summary(text: String, taskID: Int64 = 0) -> MinuteSummary {
            MinuteSummary(
                minuteStart: minute, text: text,
                apps: AppList.join(apps),
                keystrokes: keystrokes, clicks: clicks,
                shortcuts: shortcuts, fields: fields,
                sourceCount: sourceCount, taskID: taskID, isDemo: false
            )
        }
    }

    /// Fuses a minute's raw rows into a context object, or nil if the minute had
    /// no meaningful activity.
    static func buildMinuteContext(minute: Date, narratives: [SceneNarrative], spans: [ActivitySpan], transfers: [Transfer] = [], idleSeconds: TimeInterval, idleFractionForAway: Double) -> MinuteContext? {
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
        return MinuteContext(minute: minute, apps: apps, keystrokes: keystrokes, clicks: clicks, shortcuts: shortcuts, fields: fields, sceneTexts: sceneTexts, sourceCount: narratives.count, isAway: false,
                             record: StoryWriter.minuteRecord(spans: spans, transfers: transfers, narratives: narratives))
    }

    // MARK: - Pure task grouping

    /// Groups consecutive same-task minutes. Returns closed groups (ready to
    /// summarize) and the trailing pending run (too recent to close yet).
    /// A point where the apps in use turned over. The model is asked whether
    /// the job changed there; `ruleSaysNew` is what the persistence rule would
    /// decide on its own, used when there is no model or no usable answer.
    struct BoundaryQuery: Equatable {
        var key: Int64
        var episode: [MinuteSummary]
        var next: [MinuteSummary]
        var ruleSaysNew: Bool
    }

    static func boundaryKey(_ m: MinuteSummary) -> Int64 { Int64(m.minuteStart.timeIntervalSince1970) }

    /// Rules only: an idle gap, the ceiling, or a change of apps that holds.
    static func groupMinutes(_ minutes: [MinuteSummary], now: Date, config: Config) -> (closed: [[MinuteSummary]], pending: [MinuteSummary]) {
        let r = groupMinutes(minutes, now: now, config: config, decisions: [:], askJudge: false)
        return (r.closed, r.pending)
    }

    /// A task ends at an idle gap, at the ceiling, or where the model says the
    /// job changed. Splitting on a fixed clock produced "Code workflow" cards
    /// that were really time buckets, and splitting on any single minute's app
    /// change shreds genuine cross-app work, so a turnover is a question, not
    /// an answer: with `askJudge` the walk stops at the first undecided turnover
    /// and returns it as `query`; the caller decides and calls again. Without a
    /// judge, a change that holds for the next minute too ends the job.
    static func groupMinutes(_ minutes: [MinuteSummary], now: Date, config: Config, decisions: [Int64: Bool], askJudge: Bool) -> (closed: [[MinuteSummary]], pending: [MinuteSummary], query: BoundaryQuery?) {
        let sorted = minutes.sorted { $0.minuteStart < $1.minuteStart }
        var groups: [[MinuteSummary]] = []
        var current: [MinuteSummary] = []

        func appSet(_ m: MinuteSummary) -> Set<String> {
            Set(AppList.appNames(m.apps))
        }

        for (i, m) in sorted.enumerated() {
            if current.isEmpty { current = [m]; continue }
            let prev = current.last!
            let gap = m.minuteStart.timeIntervalSince(prev.minuteStart.addingTimeInterval(60))
            let tooLong = current.count >= config.maxTaskMinutes

            // Turnover: nothing this minute overlaps what the job has been doing.
            var turnedOver = false
            if config.splitOnContextChange && current.count >= config.minTaskMinutes {
                let running = current.suffix(3).reduce(into: Set<String>()) { $0.formUnion(appSet($1)) }
                let here = appSet(m)
                if !here.isEmpty && !running.isEmpty && here.isDisjoint(with: running) {
                    let next = i + 1 < sorted.count ? appSet(sorted[i + 1]) : here
                    let ruleSaysNew = next.isEmpty || !next.isDisjoint(with: here)
                    if let decided = decisions[boundaryKey(m)] {
                        turnedOver = decided
                    } else if askJudge {
                        let following = Array(sorted[i..<min(i + 3, sorted.count)])
                        return ([], [], BoundaryQuery(key: boundaryKey(m), episode: current, next: following, ruleSaysNew: ruleSaysNew))
                    } else {
                        turnedOver = ruleSaysNew
                    }
                }
            }

            if gap > config.taskGapSeconds || tooLong || turnedOver {
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
        return (closed, pending, nil)
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
            // The app name alone (the part before the dash) makes a compact
            // task-level list.
            for app in AppList.appNames(m.apps) where !seen.contains(app) {
                seen.insert(app); out.append(app)
            }
        }
        return out
    }

    // MARK: - Automatable heuristic (transparent, signal-based)

    /// Reads the fused signals for automation potential. Copy/paste chains across
    /// apps and heavy repeated field entry score high; browsing/reading scores low.
    /// The Story card's automation line, from the same Verdict as the Workflows
    /// tab. `daysObserved` and `occurrences` describe how often this shape of work
    /// has been seen, so a single sitting can never read as "High".
    static func automatableAssessment(_ minutes: [MinuteSummary], occurrences: Int, daysObserved: Int,
                                      transfers: Int, durations: [TimeInterval]) -> String {
        let shortcutsBlob = minutes.map(\.shortcuts).joined(separator: ", ")
        var fieldRuns: [String: Int] = [:]
        for m in minutes {
            for raw in m.fields.split(separator: ",") {
                if let f = Evidence.cleanField(String(raw)) { fieldRuns[f, default: 0] += 1 }
            }
        }
        let keys = minutes.reduce(0) { $0 + $1.keystrokes }
        let clicks = minutes.reduce(0) { $0 + $1.clicks }
        let seconds = Double(minutes.count) * 60
        let evidence = Evidence(
            occurrences: occurrences,
            daysObserved: daysObserved,
            durations: durations,
            transfers: transfers > 0 ? transfers : countOccurrences(of: ["⌘V"], in: shortcutsBlob),
            consistentFields: fieldRuns.keys.sorted(),
            keystrokes: keys, clicks: clicks,
            switches: max(0, mergedApps(minutes).count - 1),
            readingSeconds: Double(minutes.filter { $0.keystrokes == 0 && $0.clicks == 0 && $0.shortcuts.isEmpty }.count) * 60,
            totalSeconds: seconds
        )
        return Verdict.assess(evidence).display
    }

    /// Kept for the old single-slice call shape used by tests of the raw scoring.
    static func legacyAutomatableAssessment(_ minutes: [MinuteSummary]) -> String {
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

    static func parseTitleAndStory(_ raw: String?, fallbackApps: [String], fallbackStory: String? = nil) -> (title: String, story: String) {
        let fallbackTitle = StoryWriter.plainTitle(apps: fallbackApps)
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
