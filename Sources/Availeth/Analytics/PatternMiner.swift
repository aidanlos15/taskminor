import Foundation

/// Detects repeated cross-app sequences in the activity stream.
///
/// Approach (deterministic, no ML): collapse the span stream into a per-session
/// sequence of app symbols, mine frequent n-grams (length 3–6) with greedy
/// non-overlapping counting, drop patterns subsumed by longer ones, then score
/// each survivor's automation potential with a transparent heuristic.
enum PatternMiner {

    struct Config {
        /// A gap longer than this splits the stream into separate sessions.
        var sessionGap: TimeInterval = 15 * 60
        /// Minimum times a sequence must repeat to count as a workflow.
        var minOccurrences: Int = 3
        var minLength: Int = 3
        var maxLength: Int = 6
        /// Ignore micro-switches shorter than this when building the sequence.
        var minSpanDuration: TimeInterval = 5
        var maxResults: Int = 12
        /// Apps that are noise for workflow mining (chat/meetings), mirroring
        /// vendor practice of excluding "inherently noisy" communication apps.
        var noiseApps: Set<String> = ["Slack", "Messages", "zoom.us", "Zoom", "Discord", "FaceTime", "Microsoft Teams"]

        init() {}
    }

    /// One occurrence of a candidate pattern: where it sits in the stream and
    /// how much active time it consumed.
    private struct Instance {
        var sessionIndex: Int
        var start: Int
        var length: Int
        var activeDuration: TimeInterval
        var titles: [String]
        /// Titles seen at each step position (parallel to the app sequence).
        var stepTitles: [[String]]
        /// Wall-clock span of this occurrence, for drilling into what happened.
        var window: DateInterval

        func overlaps(_ other: Instance) -> Bool {
            sessionIndex == other.sessionIndex
                && start < other.start + other.length
                && other.start < start + length
        }
    }

    private struct Candidate {
        var apps: [String]
        var instances: [Instance]
        /// Sequence positions this pattern explains — the selection criterion.
        var coverage: Int { apps.count * instances.count }
        var key: String { apps.joined(separator: "\u{1F}") }
    }

    static func mine(spans: [ActivitySpan], config: Config = Config()) -> [WorkflowPattern] {
        let days = max(1, Analytics.workdaysObserved(spans))
        let sessions = sessionize(spans, config: config)

        // Collect candidates across all sessions, keyed by the app sequence.
        var candidates: [String: Candidate] = [:]
        for (sessionIndex, session) in sessions.enumerated() {
            guard session.count >= config.minLength else { continue }
            for n in config.minLength...config.maxLength {
                guard session.count >= n else { break }
                collectNGrams(session: session, sessionIndex: sessionIndex, n: n, into: &candidates)
            }
        }

        // Keep frequent candidates, dropping wrap-around windows of repeating
        // loops (e.g. Mail>Prev>Excel>Chrome>Mail when the true unit is the
        // 4-cycle) — their period-length version is a separate candidate.
        var frequent = candidates.values.filter {
            $0.instances.count >= config.minOccurrences
                && !isCyclicWrap($0.apps, minPeriod: config.minLength)
        }

        // Longest-first selection with instance-level dedup: an occurrence
        // already explained by a kept pattern never counts again, so sub-
        // patterns and rotations collapse and UI totals never double-count.
        frequent.sort {
            if $0.apps.count != $1.apps.count { return $0.apps.count > $1.apps.count }
            if $0.instances.count != $1.instances.count { return $0.instances.count > $1.instances.count }
            return $0.key < $1.key
        }
        var kept: [Candidate] = []
        var keptInstances: [Instance] = []
        for var cand in frequent {
            cand.instances = cand.instances.filter { inst in
                !keptInstances.contains { inst.overlaps($0) }
            }
            guard cand.instances.count >= config.minOccurrences else { continue }
            kept.append(cand)
            keptInstances.append(contentsOf: cand.instances)
        }

        var patterns = kept.map { cand -> WorkflowPattern in
            let durations = cand.instances.map(\.activeDuration).sorted()
            let median = durations[durations.count / 2]
            let total = durations.reduce(0, +)
            let titles = representativeTitles(cand.instances)
            return WorkflowPattern(
                apps: cand.apps,
                occurrences: cand.instances.count,
                medianDuration: median,
                totalDuration: total,
                daysObserved: days,
                daysSeen: TransferMiner.distinctDays(cand.instances.map(\.window.start)),
                automationScore: score(apps: cand.apps, durations: durations),
                sampleTitles: titles,
                windows: cand.instances.map(\.window).sorted { $0.start < $1.start },
                stepLabels: stepLabels(apps: cand.apps, instances: cand.instances)
            )
        }
        patterns.sort {
            if $0.automationScore != $1.automationScore { return $0.automationScore > $1.automationScore }
            return $0.totalDuration > $1.totalDuration
        }
        return Array(patterns.prefix(config.maxResults))
    }

    // MARK: - Sessionization

    /// A session item: one collapsed run of consecutive spans in the same UNIT
    /// (site/service for browsers, app otherwise). `app` holds that unit label.
    struct SequenceItem: Equatable {
        var app: String   // the workflow unit (e.g. "NetSuite", "Excel", "Temu")
        var duration: TimeInterval
        var titles: [String]
        var start: Date = .distantPast
        var end: Date = .distantPast
    }

    /// Splits spans into sessions on idle gaps, filters noise, and collapses
    /// consecutive spans in the same unit — so distinct browser tabs (NetSuite
    /// vs Temu) are separate steps, never lumped together as "Chrome".
    static func sessionize(_ spans: [ActivitySpan], config: Config = Config()) -> [[SequenceItem]] {
        let usable = spans
            .filter { $0.duration >= config.minSpanDuration && !config.noiseApps.contains($0.appName) }
            .sorted { $0.start < $1.start }
        guard !usable.isEmpty else { return [] }

        var sessions: [[SequenceItem]] = []
        var current: [SequenceItem] = []
        var lastEnd: Date?

        for span in usable {
            let unit = WorkflowUnit.label(app: span.appName, title: span.windowTitle)
            if let prev = lastEnd, span.start.timeIntervalSince(prev) > config.sessionGap {
                if !current.isEmpty { sessions.append(current) }
                current = []
            }
            if var last = current.last, last.app == unit {
                last.duration += span.duration
                if !span.windowTitle.isEmpty { last.titles.append(span.windowTitle) }
                last.end = max(last.end, span.end)
                current[current.count - 1] = last
            } else {
                current.append(SequenceItem(
                    app: unit,
                    duration: span.duration,
                    titles: span.windowTitle.isEmpty ? [] : [span.windowTitle],
                    start: span.start,
                    end: span.end
                ))
            }
            lastEnd = max(lastEnd ?? span.end, span.end)
        }
        if !current.isEmpty { sessions.append(current) }
        return sessions
    }

    // MARK: - N-gram collection

    private static func collectNGrams(session: [SequenceItem], sessionIndex: Int, n: Int, into candidates: inout [String: Candidate]) {
        // Greedy non-overlapping matching per pattern: track, for each pattern
        // key, the next index in this session at which it may match again.
        var nextAllowed: [String: Int] = [:]
        var i = 0
        while i + n <= session.count {
            let window = Array(session[i..<(i + n)])
            let apps = window.map(\.app)
            // A workflow must span more than one app.
            guard Set(apps).count > 1 else { i += 1; continue }
            let key = apps.joined(separator: "\u{1F}")
            if i >= (nextAllowed[key] ?? 0) {
                var cand = candidates[key] ?? Candidate(apps: apps, instances: [])
                let winStart = window.first?.start ?? .distantPast
                let winEnd = max(window.last?.end ?? .distantPast, winStart)
                cand.instances.append(Instance(
                    sessionIndex: sessionIndex,
                    start: i,
                    length: n,
                    activeDuration: window.reduce(0) { $0 + $1.duration },
                    titles: window.flatMap(\.titles),
                    stepTitles: window.map(\.titles),
                    window: DateInterval(start: winStart, end: winEnd)
                ))
                candidates[key] = cand
                nextAllowed[key] = i + n
            }
            i += 1
        }
    }

    /// True when the sequence is a window into a repetition of a shorter cycle
    /// (period >= minPeriod), e.g. [A,B,C,D,A] over the cycle A,B,C,D.
    static func isCyclicWrap(_ seq: [String], minPeriod: Int) -> Bool {
        guard seq.count > minPeriod else { return false }
        for period in minPeriod..<seq.count {
            var matches = true
            for i in 0..<seq.count where seq[i] != seq[i % period] {
                matches = false
                break
            }
            if matches { return true }
        }
        return false
    }

    /// The most common normalized window title at each step position, so the
    /// step map reads "Chrome (Vendor Bills — NetSuite)" not just "Chrome".
    private static func stepLabels(apps: [String], instances: [Instance]) -> [String] {
        (0..<apps.count).map { pos in
            var counts: [String: Int] = [:]
            for inst in instances where pos < inst.stepTitles.count {
                for t in inst.stepTitles[pos] {
                    let norm = Analytics.normalizeTitle(t, appName: apps[pos])
                    if !norm.isEmpty && !norm.hasPrefix("General ") { counts[norm, default: 0] += 1 }
                }
            }
            return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key ?? ""
        }
    }

    private static func representativeTitles(_ instances: [Instance]) -> [String] {
        var counts: [String: Int] = [:]
        for inst in instances {
            for t in inst.titles where !t.isEmpty {
                counts[t, default: 0] += 1
            }
        }
        // Deterministic across launches: tie-break by title.
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3)
            .map(\.key)
    }

    // MARK: - Scoring

    /// Apps whose workflows are typically automatable (structured, API-backed work).
    private static let automatableApps: Set<String> = [
        "Mail", "Microsoft Outlook", "Outlook", "Microsoft Excel", "Excel", "Numbers",
        "Google Chrome", "Safari", "Microsoft Edge", "Arc", "Preview", "Finder",
        "Calendar", "Notes", "QuickBooks", "Salesforce", "NetSuite",
    ]

    /// Transparent 0–100 heuristic:
    ///  - repetition weight (up to 40): more occurrences → more automatable
    ///  - consistency weight (up to 30): low duration variance → rule-like work
    ///  - app-mix weight (up to 20): structured/API-backed apps score higher
    ///  - length bonus (up to 10): longer chains carry more recoverable effort
    static func score(apps: [String], durations: [TimeInterval]) -> Int {
        let count = durations.count
        let repetition = min(40.0, Double(count) / 20.0 * 40.0)

        let mean = durations.reduce(0, +) / Double(max(1, count))
        let variance = durations.reduce(0) { $0 + pow($1 - mean, 2) } / Double(max(1, count))
        let cv = mean > 0 ? sqrt(variance) / mean : 1.0
        // CV of 0 → full 30 points; CV >= 1.2 → 0 points.
        let consistency = max(0.0, 30.0 * (1.0 - min(1.0, cv / 1.2)))

        let automatableFraction = Double(apps.filter { automatableApps.contains($0) }.count) / Double(apps.count)
        let appMix = automatableFraction * 20.0

        let lengthBonus = apps.count >= 5 ? 10.0 : (apps.count == 4 ? 7.0 : 4.0)

        return min(98, max(5, Int((repetition + consistency + appMix + lengthBonus).rounded())))
    }
}
