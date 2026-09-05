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
