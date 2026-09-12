import Foundation

/// The time-aligned track a downstream tool needs to annotate a walkthrough
/// video: every event of a run with its offset into the exported clip, and a
/// storyboard scoring each 30-second stretch so the tool knows what to dwell
/// on and what to fast-forward. Pure functions over stored data.
enum ExportTimeline {
    struct Event: Equatable {
        /// Seconds into the exported clip (nil when that moment wasn't recorded).
        var t: Double?
        var timestamp: Date
        /// focus · scene · note · copy · cut · paste · save · commit · click · typing · away
        var kind: String
        var app: String = ""
        var title: String = ""
        var host: String = ""
        var x: Double? = nil
        var y: Double? = nil
        var display: Int = 0
        var label: String = ""
        var count: Int = 0
        var text: String = ""
        /// For focus events: how long that window stayed in front (wall seconds).
        var duration: Double? = nil
        /// Clip time where a focus stretch ends (nil if unrecorded).
        var tEnd: Double? = nil
        /// False when a clip exists but this instant fell in a recording gap.
        var recorded: Bool = true
        /// Focus events: the fields typed into and the shortcut summary for that window.
        var fields: String = ""
        var shortcuts: String = ""
    }

    private static func squash(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Merges spans (focus), narratives (scene), minute notes (note), input
    /// events and idle stretches (away) inside `interval`, time-ordered.
    static func events(interval: DateInterval, spans: [ActivitySpan], narratives: [SceneNarrative], minutes: [MinuteSummary],
                       inputEvents: [InputEvent], idles: [IdleSession], clip: Recordings.Clip?) -> [Event] {
        // With a clip, `t` is clip time and an instant in a recording gap has
        // none; without one, `t` is seconds from the interval start ("wall").
        func offset(_ d: Date) -> Double? {
            if let clip { return clip.time(for: d).map { ($0.seconds * 100).rounded() / 100 } }
            return max(0, (d.timeIntervalSince(interval.start) * 100).rounded() / 100)
        }
        func make(_ d: Date, _ kind: String) -> Event {
            let t = offset(d)
            return Event(t: t, timestamp: d, kind: kind, recorded: clip == nil || t != nil)
        }
        var out: [Event] = []
        for s in spans where s.end > interval.start && s.start < interval.end {
            let start = max(s.start, interval.start), end = min(s.end, interval.end)
            var e = make(start, "focus")
            e.app = s.appName; e.title = LabelKey.cleanTitle(s.windowTitle, appName: s.appName); e.host = s.pageHost
            e.fields = s.fields; e.shortcuts = s.shortcuts
            e.duration = (end.timeIntervalSince(start) * 10).rounded() / 10
            e.tEnd = offset(end)
            out.append(e)
        }
        for n in narratives where interval.contains(n.timestamp) {
            var e = make(n.timestamp, "scene"); e.app = n.appName; e.title = n.windowTitle; e.text = n.text; out.append(e)
        }
        for m in minutes where m.minuteStart >= interval.start.addingTimeInterval(-60) && m.minuteStart < interval.end && !m.text.isEmpty && m.text != "Away from keyboard" {
            var e = make(max(m.minuteStart, interval.start), "note"); e.app = m.apps; e.text = StoryFormat.plain(m.text); out.append(e)
        }
        for i in inputEvents where interval.contains(i.timestamp) {
            var e = make(i.timestamp, i.kind.rawValue)
            e.app = i.appName; e.x = i.x; e.y = i.y; e.display = i.display; e.label = i.label; e.count = i.count
            out.append(e)
        }
        for i in idles where i.end > interval.start && i.start < interval.end {
            let start = max(i.start, interval.start)
            var e = make(start, "away"); e.duration = min(i.end, interval.end).timeIntervalSince(start); out.append(e)
        }
        return out.sorted { $0.timestamp != $1.timestamp ? $0.timestamp < $1.timestamp : $0.kind < $1.kind }
    }

    /// One JSON object per line.
    static func jsonl(_ events: [Event]) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = []
        for e in events {
            var o: [String: Any] = ["ts": iso.string(from: e.timestamp), "kind": e.kind]
            if let t = e.t { o["t"] = t }
            if let tEnd = e.tEnd { o["tEnd"] = tEnd }
            if !e.recorded { o["recorded"] = false }
            if !e.app.isEmpty { o["app"] = e.app }
            if !e.title.isEmpty { o["title"] = e.title }
            if !e.host.isEmpty { o["host"] = e.host }
            if let x = e.x, let y = e.y { o["x"] = x; o["y"] = y; o["display"] = e.display }
            if !e.label.isEmpty { o["label"] = e.label }
            if !e.fields.isEmpty { o["fields"] = e.fields }
            if !e.shortcuts.isEmpty { o["shortcuts"] = e.shortcuts }
            if e.count > 0 { o["count"] = e.count }
            if !e.text.isEmpty { o["text"] = e.text }
            if let d = e.duration { o["duration"] = d }
            if let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), let s = String(data: data, encoding: .utf8) {
                lines.append(s)
            }
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    // MARK: - Storyboard

    struct Window: Equatable {
        var start: Date
        var end: Date
        /// Clip time of the window's start and end (nil when unrecorded).
        var t: Double?
        var tEnd: Double?
        var score: Double
        /// "1×", "2×" or "5× fast-forward".
        var suggestion: String
        /// What happened, one line each.
        var summary: [String]
        /// Which earlier window this repeats (same windows, no data moved), if any.
        var repeats: Int?
    }

    /// Scores each `step`-second stretch by how much a viewer learns from it:
    /// new windows and data movements score high; a stretch that shows the
    /// same windows as an earlier one with no data moved is a repeat.
    /// `time` maps a wall-clock instant to clip seconds (nil = unrecorded);
    /// pass nil when there is no clip and `t` is seconds from the start.
    static func storyboard(interval: DateInterval, events: [Event], step: TimeInterval = 30, time: ((Date) -> Double?)? = nil) -> [Window] {
        let map: (Date) -> Double? = time ?? { d in max(0, (d.timeIntervalSince(interval.start) * 100).rounded() / 100) }
        var out: [Window] = []
        var seenPairs = Set<String>()
        var pairSets: [Set<String>] = []
        var t = interval.start
        while t < interval.end {
            let end = min(t.addingTimeInterval(step), interval.end)
            let inside = events.filter { $0.timestamp >= t && $0.timestamp < end }
            var score = 0.0
            var summary: [String] = []
            var pairs = Set<String>()
            var dataMoved = false
            var typing = 0.0, clicks = 0.0, focus = 0.0
            for e in inside {
                switch e.kind {
                case "focus":
                    let pair = e.app + "\u{1F}" + e.title
                    // Each window counts once per stretch: alt-tab churn is not novelty.
                    guard !pairs.contains(pair) else { continue }
                    pairs.insert(pair)
                    if seenPairs.contains(pair) { focus += 1 } else { focus += 3; seenPairs.insert(pair) }
                    summary.append(squash("\(e.app)" + (e.title.isEmpty ? "" : " \u{2014} \(e.title)") + (e.host.isEmpty ? "" : " (\(e.host))")))
                case "copy", "cut", "paste", "save", "commit":
                    score += 2; dataMoved = true
                    summary.append(squash(e.kind + (e.label.isEmpty ? "" : " \u{2014} \(e.label)") + " in \(e.app)"))
                case "scene":
                    score += 1
                    summary.append(squash(StoryFormat.sentences(e.text).first ?? e.text))
                case "note":
                    score += 0.5
                case "typing": typing = min(2, typing + 0.5)
                case "click": clicks = min(1, clicks + 0.2)
                case "away": score -= 3; summary.append("away from keyboard")
                default: break
                }
            }
            score += min(6, focus) + typing + clicks
            var repeats: Int?
            if !pairs.isEmpty, !dataMoved, let prior = pairSets.firstIndex(of: pairs), prior < pairSets.count {
                score -= 2
                repeats = prior + 1
            }
            pairSets.append(pairs)
            let suggestion = score >= 4 ? "1\u{00D7}" : (score >= 2 ? "2\u{00D7}" : "5\u{00D7} fast-forward")
            out.append(Window(start: t, end: end, t: map(t), tEnd: map(end),
                              score: (score * 10).rounded() / 10, suggestion: suggestion, summary: Array(summary.prefix(6)), repeats: repeats))
            t = end
        }
        return out
    }

    /// The storyboard as JSON-ready rows for the manifest.
    static func storyboardJSON(_ windows: [Window]) -> [[String: Any]] {
        let iso = ISO8601DateFormatter()
        return windows.enumerated().map { i, w in
            var o: [String: Any] = ["index": i + 1, "start": iso.string(from: w.start), "end": iso.string(from: w.end),
                                    "score": w.score, "suggest": w.suggestion, "summary": w.summary]
            if let t = w.t { o["t"] = t }
            if let tEnd = w.tEnd { o["tEnd"] = tEnd }
            if let r = w.repeats { o["repeats"] = r }
            return o
        }
    }

    static func storyboardMarkdown(title: String, clip: String?, windows: [Window], step: TimeInterval = 30) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss xxx"
        var s = "# Storyboard \u{2014} \(title)\n\n"
        s += "Each row is a \(Int(step))-second stretch\(clip.map { " of `\($0)`" } ?? ""). "
        s += clip == nil ? "`t` is seconds from the start (no recording for this run). " : "`t`\u{2013}`tEnd` are seconds into the clip (blank when that stretch was not recorded). "
        s += "The score is a heuristic: new windows and data moved between apps score high; a stretch showing the same windows as an earlier one, with nothing moved, is a repeat. Suggested playback speed follows the score \u{2014} a starting point for an editor, not a verdict. Wall clock is local time with its offset; `ts` in events.jsonl is UTC.\n\n"
        s += "| # | wall clock | t | score | suggest | what happens |\n|---|---|---|---|---|---|\n"
        for (i, w) in windows.enumerated() {
            let what = (w.summary.isEmpty ? "\u{2014}" : w.summary.joined(separator: "; ")) + (w.repeats.map { " _(repeats #\($0))_" } ?? "")
            let span = w.t.map { t in String(format: "%.0f\u{2013}%@", t, w.tEnd.map { String(format: "%.0f", $0) } ?? "") } ?? "\u{2014}"
            s += "| \(i + 1) | \(f.string(from: w.start)) | \(span) | \(w.score) | \(w.suggestion) | \(squash(what).replacingOccurrences(of: "|", with: "\\|")) |\n"
        }
        return s
    }
}
