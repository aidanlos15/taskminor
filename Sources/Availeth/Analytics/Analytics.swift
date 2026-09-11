import Foundation

/// Pure functions turning raw spans into the aggregates the dashboard shows.
enum Analytics {

    static func totalTime(_ spans: [ActivitySpan]) -> TimeInterval {
        spans.reduce(0) { $0 + $1.duration }
    }

    static func timeByApp(_ spans: [ActivitySpan]) -> [AppTotal] {
        var totals: [String: AppTotal] = [:]
        for span in spans {
            var t = totals[span.bundleID] ?? AppTotal(bundleID: span.bundleID, appName: span.appName, duration: 0, spanCount: 0)
            t.duration += span.duration
            t.spanCount += 1
            totals[span.bundleID] = t
        }
        return totals.values.sorted { $0.duration > $1.duration }
    }

    /// Groups spans by normalized window title within each app.
    static func taskGroups(_ spans: [ActivitySpan]) -> [TaskGroup] {
        var groups: [String: TaskGroup] = [:]
        for span in spans {
            let title = normalizeTitle(span.windowTitle, appName: span.appName)
            let key = span.appName + "|" + title
            var g = groups[key] ?? TaskGroup(title: title, appName: span.appName, duration: 0, sessions: 0, lastSeen: span.end)
            g.duration += span.duration
            g.sessions += 1
            g.lastSeen = max(g.lastSeen, span.end)
            groups[key] = g
        }
        return groups.values.sorted { $0.duration > $1.duration }
    }

    // MARK: - Detailed, content-rich tasks

    /// Every distinct piece of work as one row. Spans group by unit (app or site)
    /// and by TASK: the intent label the labeler persisted for the span when it
    /// has one, else the cleaned window title. Bare titles ("Claude") with no
    /// label yet collapse onto the unit until the labeler names them — never a
    /// screenshot sentence. Captured narratives attach by unit and time.
    static func detailedTasks(_ spans: [ActivitySpan], narratives: [SceneNarrative], labels: [Int64: SpanLabel] = [:], calendar: Calendar = .current) -> [DetailedTask] {
        struct Group {
            var unit: String; var title: String; var source: LabelSource
            var spans: [ActivitySpan]; var titles: [String: TimeInterval]
        }
        var groups: [String: Group] = [:]
        for span in spans {
            let unit = WorkflowUnit.label(app: span.appName, title: span.windowTitle)
            let clean = LabelKey.cleanTitle(span.windowTitle, appName: span.appName)
            let title: String, source: LabelSource
            if let label = labels[span.id], !label.canon.isEmpty {
                title = label.canon; source = label.source
            } else if LabelKey.isUninformative(unit: unit, cleanTitle: clean) {
                title = unit; source = .fallback
            } else {
                title = clean; source = .title
            }
            let key = unit + "\u{1F}" + LabelKey.canonKey(title)
            var g = groups[key] ?? Group(unit: unit, title: title, source: source, spans: [], titles: [:])
            g.spans.append(span)
            g.titles[clean, default: 0] += span.duration
            if source == .model { g.source = .model }
            groups[key] = g
        }

        // Sittings per group.
        struct Built { var key: String; var g: Group; var spans: [ActivitySpan]; var runs: [SessionRun] }
        var builtByUnit: [String: [Built]] = [:]
        for (key, g) in groups {
            let sorted = g.spans.sorted { $0.start < $1.start }
            let runs: [SessionRun] = splitSpansByGap(sorted, gap: 5 * 60).compactMap { run in
                guard let first = run.first, let end = run.map(\.end).max() else { return nil }
                var byTitle: [String: TimeInterval] = [:]
                for s in run { byTitle[LabelKey.cleanTitle(s.windowTitle, appName: s.appName), default: 0] += s.duration }
                let title = byTitle.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? g.title
                return SessionRun(start: first.start, end: end, windowTitle: title, spanCount: run.count)
            }
            builtByUnit[g.unit, default: []].append(Built(key: key, g: g, spans: sorted, runs: runs))
        }

        // Each narrative attaches to the ONE task of its unit whose sitting
        // contains it; only when none does may a task within 30 s claim it, so a
        // neighbouring task's screen never becomes this task's detail.
        var narrByUnit: [String: [SceneNarrative]] = [:]
        for n in narratives.sorted(by: { $0.timestamp < $1.timestamp }) {
            narrByUnit[WorkflowUnit.label(app: n.appName, title: n.windowTitle), default: []].append(n)
        }
        var momentsByKey: [String: [SceneNarrative]] = [:]
        for (unit, items) in builtByUnit {
            let ordered = items.sorted { $0.key < $1.key }
            for n in narrByUnit[unit] ?? [] {
                func distance(_ b: Built) -> TimeInterval {
                    b.runs.map { r in
                        n.timestamp < r.start ? r.start.timeIntervalSince(n.timestamp)
                            : (n.timestamp > r.end ? n.timestamp.timeIntervalSince(r.end) : 0)
                    }.min() ?? .infinity
                }
                let target = ordered.first { distance($0) == 0 }
                    ?? ordered.filter { distance($0) <= 30 }.min { distance($0) < distance($1) }
                if let t = target { momentsByKey[t.key, default: []].append(n) }
            }
        }

        var out: [DetailedTask] = []
        for b in builtByUnit.values.joined() {
            let moments = dedupNarratives(momentsByKey[b.key] ?? [])
            let preview = moments.max(by: { $0.text.count < $1.text.count })?.text ?? ""
            let variants = b.g.titles.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
            out.append(DetailedTask(
                id: b.key, title: b.g.title, appUnit: b.g.unit,
                duration: b.spans.reduce(0) { $0 + $1.duration },
                sessions: b.runs.count, lastSeen: b.spans.map(\.end).max() ?? Date(),
                moments: moments, preview: preview, source: b.g.source, runs: b.runs, variants: variants
            ))
        }
        return out.sorted { $0.duration != $1.duration ? $0.duration > $1.duration : $0.id < $1.id }
    }

    /// Splits a time-sorted span list into sessions on gaps larger than `gap`.
    static func splitSpansByGap(_ spans: [ActivitySpan], gap: TimeInterval) -> [[ActivitySpan]] {
        var sessions: [[ActivitySpan]] = []
        var current: [ActivitySpan] = []
        var lastEnd: Date?
        for s in spans {
            if let prev = lastEnd, s.start.timeIntervalSince(prev) > gap {
                if !current.isEmpty { sessions.append(current); current = [] }
            }
            current.append(s)
            lastEnd = max(lastEnd ?? s.end, s.end)
        }
        if !current.isEmpty { sessions.append(current) }
        return sessions
    }

    /// A short human label from the content of a conversation's moments.
    static func taskLabel(from moments: [SceneNarrative]) -> String? {
        guard let text = moments.max(by: { $0.text.count < $1.text.count })?.text, !text.isEmpty else { return nil }
        // First sentence, trimmed to a headline length.
        let firstSentence = text.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? text
        var label = firstSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.count > 80 { label = String(label.prefix(80)).trimmingCharacters(in: .whitespaces) + "…" }
        return label.isEmpty ? nil : label
    }

    private static func dedupNarratives(_ ns: [SceneNarrative]) -> [SceneNarrative] {
        var out: [SceneNarrative] = []
        for n in ns where out.last?.text != n.text { out.append(n) }
        return out
    }

    /// Splits each span across the hours of the day it touches.
    /// Hour boundaries come from Calendar.dateInterval, which is sub-second-safe
    /// and correct across DST transitions (bySettingHour is neither).
    static func hourlyActivity(_ spans: [ActivitySpan], calendar: Calendar = .current) -> [HourlyActivity] {
        var buckets: [String: HourlyActivity] = [:]
        for span in spans {
            var cursor = span.start
            while cursor < span.end {
                let hour = calendar.component(.hour, from: cursor)
                var sliceEnd = span.end
                if let hourEnd = calendar.dateInterval(of: .hour, for: cursor)?.end, hourEnd < span.end {
                    sliceEnd = hourEnd
                }
                // Defensive: the loop must always advance.
                if sliceEnd <= cursor { sliceEnd = span.end }
                let key = "\(hour)|\(span.appName)"
                var b = buckets[key] ?? HourlyActivity(hour: hour, appName: span.appName, duration: 0)
                b.duration += sliceEnd.timeIntervalSince(cursor)
                buckets[key] = b
                cursor = sliceEnd
            }
        }
        return buckets.values.sorted { $0.hour < $1.hour }
    }

    /// Observed time per calendar day (for the trend chart).
    static func dailyTotals(_ spans: [ActivitySpan], calendar: Calendar = .current) -> [DailyTotal] {
        var totals: [Date: TimeInterval] = [:]
        for span in spans {
            let day = calendar.startOfDay(for: span.start)
            totals[day, default: 0] += span.duration
        }
        return totals.map { DailyTotal(day: $0.key, duration: $0.value) }.sorted { $0.day < $1.day }
    }

    /// Number of distinct calendar days covered by the spans (for extrapolation).
    static func daysObserved(_ spans: [ActivitySpan], calendar: Calendar = .current) -> Int {
        Set(spans.map { calendar.startOfDay(for: $0.start) }).count
    }

    /// Distinct weekdays (Mon–Fri) covered — the denominator for per-working-day
    /// extrapolation. Falls back to all days for weekend-only data.
    static func workdaysObserved(_ spans: [ActivitySpan], calendar: Calendar = .current) -> Int {
        let days = Set(spans.map { calendar.startOfDay(for: $0.start) })
        let workdays = days.filter {
            let weekday = calendar.component(.weekday, from: $0)
            return weekday >= 2 && weekday <= 6
        }
        return workdays.isEmpty ? days.count : workdays.count
    }

    /// Strips browser/app suffixes and noise from a window title so that
    /// "Purchase Orders.xlsx — Excel" and "Purchase Orders.xlsx" group together.
    static func normalizeTitle(_ raw: String, appName: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return "General \(appName) usage" }

        // Strip trailing " - AppName" / " — AppName" / " – AppName" suffixes.
        for dash in [" — ", " – ", " - "] {
            if let range = title.range(of: dash + appName, options: [.backwards, .caseInsensitive]),
               range.upperBound == title.endIndex {
                title = String(title[..<range.lowerBound])
            }
        }
        // Browsers append their own product names.
        for suffix in [" — Google Chrome", " - Google Chrome", " — Safari", " - Safari", " — Microsoft Edge", " - Microsoft Edge"] {
            if title.hasSuffix(suffix) {
                title = String(title.dropLast(suffix.count))
            }
        }
        // Collapse mailbox unread counts: "Inbox (42)" -> "Inbox".
        // 1–3 digits only, so identity-bearing years like "Report (2024)" survive.
        if let range = title.range(of: #" \(\d{1,3}\)$"#, options: .regularExpression) {
            title = String(title[..<range.lowerBound])
        }
        title = title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "General \(appName) usage" : title
    }
}
