import Foundation

/// Finds chores by what moved, not by where the user was.
///
/// The sequence miner looks for repeated orders of windows and cannot tell "reply
/// to a review request" from "glance at the inbox", because both are Code, Outlook,
/// Code. This miner starts from transfers instead: a copy in one context followed
/// by a paste in another. A run of those close together is an entry; entries with
/// the same shape (the same hops between units) recurring across days are a
/// workflow. That is the sentence Availeth needs to be able to say: "invoice data
/// is moved from email into Excel and then into NetSuite by hand, forty times a
/// week."
enum TransferMiner {
    struct Config {
        /// Two transfers closer than this belong to the same entry.
        var chainGap: TimeInterval = 180
        /// How much of the surrounding activity counts as part of a run.
        var pad: TimeInterval = 90
        var minOccurrences = 3
        var maxResults = 12
        init() {}
    }

    /// One sitting's worth of related transfers.
    struct Entry: Equatable {
        var transfers: [Transfer]
        var start: Date { (transfers.first.map { $0.at.addingTimeInterval(-$0.gapSeconds) }) ?? .distantPast }
        var end: Date { transfers.last?.at ?? .distantPast }
        /// The hop sequence with consecutive repeats collapsed: the shape's key.
        var hops: [String] {
            var out: [String] = []
            for t in transfers where out.last != t.hop { out.append(t.hop) }
            return out
        }
        var shapeKey: String { hops.joined(separator: " | ") }
    }

    static func entries(_ transfers: [Transfer], config: Config = Config()) -> [Entry] {
        let sorted = transfers.sorted { $0.at < $1.at }
        var out: [Entry] = []
        var current: [Transfer] = []
        for t in sorted {
            if let last = current.last, t.at.timeIntervalSince(last.at) > config.chainGap {
                out.append(Entry(transfers: current)); current = []
            }
            current.append(t)
        }
        if !current.isEmpty { out.append(Entry(transfers: current)) }
        return out
    }

    /// The units an entry shape passes through, in order: ["Mail", "Excel", "NetSuite"].
    static func units(forHops hops: [String]) -> [String] {
        var out: [String] = []
        for hop in hops {
            let parts = hop.components(separatedBy: " → ")
            for p in parts where out.last != p { if !out.contains(p) || out.last != p { out.append(p) } }
        }
        // Collapse exact consecutive duplicates only; a unit may legitimately recur later.
        var collapsed: [String] = []
        for u in out where collapsed.last != u { collapsed.append(u) }
        return collapsed
    }

    static func mine(transfers: [Transfer], spans: [ActivitySpan], config: Config = Config()) -> [WorkflowPattern] {
        let days = max(1, Analytics.workdaysObserved(spans))
        var byShape: [String: [Entry]] = [:]
        for e in entries(transfers, config: config) { byShape[e.shapeKey, default: []].append(e) }

        var patterns: [WorkflowPattern] = []
        for (key, runs) in byShape where runs.count >= config.minOccurrences {
            let hops = runs[0].hops
            let unitList = units(forHops: hops)
            let unitSet = Set(unitList)

            // A run's active time and input is whatever happened in the shape's
            // units around its transfers, padded a little on each side.
            var windows: [DateInterval] = []
            var durations: [TimeInterval] = []
            var occSpans: [[ActivitySpan]] = []
            for run in runs {
                let a = run.start.addingTimeInterval(-config.pad), b = run.end.addingTimeInterval(config.pad)
                let inRun = spans.filter { $0.end > a && $0.start < b && unitSet.contains(WorkflowUnit.label(app: $0.appName, title: $0.windowTitle)) }
                occSpans.append(inRun)
                let active = inRun.reduce(0.0) { $0 + min($1.end, b).timeIntervalSince(max($1.start, a)) }
                durations.append(max(active, run.end.timeIntervalSince(run.start), 10))
                windows.append(DateInterval(start: a, end: max(b, a.addingTimeInterval(10))))
            }
            let sortedDurations = durations.sorted()
            let evidence = Evidence.gather(occSpans: occSpans, transfers: runs.flatMap(\.transfers), daysObserved: distinctDays(runs.map(\.end)), durations: durations)
            let verdict = Verdict.assess(evidence)

            let titles = representativeTitles(runs)
            patterns.append(WorkflowPattern(
                apps: unitList,
                occurrences: runs.count,
                medianDuration: sortedDurations[sortedDurations.count / 2],
                totalDuration: durations.reduce(0, +),
                daysObserved: days,
                daysSeen: distinctDays(runs.map(\.end)),
                automationScore: verdict.score,
                sampleTitles: titles,
                windows: windows.sorted { $0.start < $1.start },
                stepLabels: stepLabels(units: unitList, runs: runs),
                source: .transfers,
                fields: evidence.consistentFields,
                transferCount: runs.reduce(0) { $0 + $1.transfers.count },
                verdict: verdict
            ))
            _ = key
        }
        patterns.sort {
            if ($0.verdict?.isCandidate ?? false) != ($1.verdict?.isCandidate ?? false) { return $0.verdict?.isCandidate ?? false }
            if $0.automationScore != $1.automationScore { return $0.automationScore > $1.automationScore }
            return $0.totalDuration > $1.totalDuration
        }
        return Array(patterns.prefix(config.maxResults))
    }

    static func distinctDays(_ dates: [Date]) -> Int {
        let cal = Calendar.current
        return Set(dates.map { cal.startOfDay(for: $0) }).count
    }

    private static func representativeTitles(_ runs: [Entry]) -> [String] {
        var counts: [String: Int] = [:]
        for r in runs { for t in r.transfers { counts[t.fromTitle, default: 0] += 1; counts[t.toTitle, default: 0] += 1 } }
        return counts.filter { !$0.key.isEmpty }.sorted { $0.value > $1.value }.prefix(4).map(\.key)
    }

    private static func stepLabels(units: [String], runs: [Entry]) -> [String] {
        // Most common title seen for each unit across all transfers.
        var byUnit: [String: [String: Int]] = [:]
        for r in runs {
            for t in r.transfers {
                if !t.fromTitle.isEmpty { byUnit[t.fromUnit, default: [:]][t.fromTitle, default: 0] += 1 }
                if !t.toTitle.isEmpty { byUnit[t.toUnit, default: [:]][t.toTitle, default: 0] += 1 }
            }
        }
        return units.map { u in byUnit[u]?.max { $0.value < $1.value }?.key ?? u }
    }
}

extension Evidence {
    /// Builds evidence from the spans of each run plus the transfers that fell
    /// inside them. Used for transfer-derived and sequence-derived patterns alike,
    /// so both get the same judgement.
    static func gather(occSpans: [[ActivitySpan]], transfers: [Transfer], daysObserved: Int, durations: [TimeInterval]) -> Evidence {
        let all = occSpans.flatMap { $0 }
        let runs = max(1, occSpans.count)

        // Fields that appear on at least half the runs, with the deep-mode class
        // stripped and obvious UI chrome removed.
        var fieldRuns: [String: Int] = [:]
        for run in occSpans {
            var seen = Set<String>()
            for s in run {
                for raw in s.fields.split(separator: ",") {
                    if let f = cleanField(String(raw)) { seen.insert(f) }
                }
            }
            for f in seen { fieldRuns[f, default: 0] += 1 }
        }
        let consistent = fieldRuns.filter { $0.value * 2 >= runs }.keys.sorted()

        // Reading means nothing happened at all. A span holding a copy or a
        // paste is work even when nothing was typed, so shortcuts count as
        // activity; treating them as reading penalised the very movements this
        // miner exists to find.
        let reading = all.filter { $0.keystrokes == 0 && $0.clicks == 0 && $0.shortcuts.isEmpty }
            .reduce(0.0) { $0 + $1.duration }
        let total = all.reduce(0.0) { $0 + $1.duration }
        return Evidence(
            occurrences: occSpans.count,
            daysObserved: daysObserved,
            durations: durations,
            transfers: transfers.count,
            consistentFields: consistent,
            keystrokes: all.reduce(0) { $0 + $1.keystrokes },
            clicks: all.reduce(0) { $0 + $1.clicks },
            switches: max(0, all.count - occSpans.count),
            readingSeconds: reading,
            totalSeconds: total
        )
    }

    /// "Amount [currency]" → "Amount"; drops address bars, search boxes and
    /// placeholders that are not form fields.
    static func cleanField(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if let b = t.firstIndex(of: "[") { t = String(t[..<b]).trimmingCharacters(in: .whitespaces) }
        guard t.count >= 2, t.count <= 40 else { return nil }
        // Numbers, web addresses and cut-off screen text are not field labels.
        // Old rows hold plenty of them, so they are dropped on the way out too.
        guard FieldClassifier.isUsableLabel(t) else { return nil }
        let lower = t.lowercased()
        let chrome = ["search", "search or enter website name", "address and search bar", "enter your email", "save as:", "search apps", "find", "filter"]
        if chrome.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) { return nil }
        return t
    }
}
