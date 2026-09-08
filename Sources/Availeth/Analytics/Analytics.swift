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

    /// Like `taskGroups`, but attaches the captured detailed narratives to each
    /// task and splits generic lumps (e.g. all "Claude" usage) into distinct
    /// conversations by content, so each row says WHAT the work actually was.
    static func detailedTasks(_ spans: [ActivitySpan], narratives: [SceneNarrative], calendar: Calendar = .current) -> [DetailedTask] {
        // 1. Collect spans per task key (unit + normalized title).
        struct Group { var unit: String; var title: String; var generic: Bool; var spans: [ActivitySpan] }
        var groups: [String: Group] = [:]
        for span in spans {
            let unit = WorkflowUnit.label(app: span.appName, title: span.windowTitle)
            let title = normalizeTitle(span.windowTitle, appName: span.appName)
            let key = unit + "\u{1F}" + title
            // "Generic" = the title says nothing beyond the app/site (e.g. a bare
            // "Claude" or "ChatGPT" window) → worth splitting into conversations.
            let generic = title.hasPrefix("General ") || title == unit
            var g = groups[key] ?? Group(unit: unit, title: title, generic: generic, spans: [])
            g.spans.append(span)
            groups[key] = g
        }
        // 2. Index narratives by the same key.
        let sortedNarr = narratives.sorted { $0.timestamp < $1.timestamp }
        var narrByKey: [String: [SceneNarrative]] = [:]
        for n in sortedNarr {
            let key = WorkflowUnit.label(app: n.appName, title: n.windowTitle) + "\u{1F}" + normalizeTitle(n.windowTitle, appName: n.appName)
            narrByKey[key, default: []].append(n)
        }

        // 3. Build tasks. Generic groups with content get split into conversations.
        var out: [DetailedTask] = []
        for (key, g) in groups {
            let groupNarr = narrByKey[key] ?? []
            if g.generic, groupNarr.count > 1 {
                let sessions = splitSpansByGap(g.spans.sorted { $0.start < $1.start }, gap: 5 * 60)
                if sessions.count > 1 {
                    for (i, sess) in sessions.enumerated() {
                        guard let s0 = sess.first?.start, let s1 = sess.last?.end else { continue }
                        let moments = groupNarr.filter { $0.timestamp >= s0.addingTimeInterval(-30) && $0.timestamp <= s1.addingTimeInterval(30) }
                        out.append(makeTask(id: "\(key)#\(i)", unit: g.unit, fallbackTitle: g.title, spans: sess, moments: moments))
                    }
                    continue
                }
            }
            out.append(makeTask(id: key, unit: g.unit, fallbackTitle: g.title, spans: g.spans, moments: groupNarr))
        }
        return out.sorted { $0.duration > $1.duration }
    }

    private static func makeTask(id: String, unit: String, fallbackTitle: String, spans: [ActivitySpan], moments raw: [SceneNarrative]) -> DetailedTask {
        let moments = dedupNarratives(raw.sorted { $0.timestamp < $1.timestamp })
        let duration = spans.reduce(0) { $0 + $1.duration }
        let lastSeen = spans.map(\.end).max() ?? Date()
        // Title: a real window title if we have one; otherwise (bare app/site
        // name, or "General …") derive a headline from the captured content.
        let uninformative = fallbackTitle.hasPrefix("General ") || fallbackTitle == unit
        let title = (uninformative ? taskLabel(from: moments) : nil) ?? fallbackTitle
        let preview = moments.max(by: { $0.text.count < $1.text.count })?.text ?? ""
        return DetailedTask(id: id, title: title, appUnit: unit, duration: duration,
                            sessions: spans.count, lastSeen: lastSeen, moments: moments, preview: preview)
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
