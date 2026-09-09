import Foundation

/// Interaction Telemetry mode — how much input structure Availeth reconstructs.
/// No mode ever reads typed characters; the tiers differ only in how much
/// *structure* (shortcuts, fields, semantic classes) they infer.
enum InputTelemetryMode: String, CaseIterable, Identifiable, Equatable {
    case off
    case standard
    case deep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .standard: return "Standard"
        case .deep: return "Deep"
        }
    }

    var blurb: String {
        switch self {
        case .off:
            return "Your keyboard and mouse are not tracked at all."
        case .standard:
            return "Records the shortcuts you use, like copy, paste and find. Records when you move between fields with Tab, and how many keys and clicks a task takes. That is what makes a repeated copy-and-paste chore stand out. Keystrokes are counted, never read, so passwords and messages are never captured. Password fields and excluded apps record nothing at all."
        case .deep:
            return "Everything in Standard. It also records the name of each field you type into, like “Amount” or “Email”. The name comes from the label on screen, never from what you type. This makes the workflow map more detailed."
        }
    }
}

/// One contiguous stretch of activity in a single app window.
/// The fundamental unit of captured data.
struct ActivitySpan: Identifiable, Equatable {
    var id: Int64 = 0
    var bundleID: String
    var appName: String
    var windowTitle: String
    var start: Date
    var end: Date
    var isDemo: Bool = false

    // Optional enrichment fields, populated only when the matching capability is
    // enabled and its permission granted. All privacy-preserving by design.
    /// Number of content keys pressed — a COUNT only, never the keys themselves.
    var keystrokes: Int = 0
    /// Number of mouse clicks during the span.
    var clicks: Int = 0
    /// Identity (path) of the document open in the focused window — NOT its
    /// contents. Read from the Accessibility document attribute.
    var documentPath: String = ""
    /// Compact summary of shortcut chords and navigation keys, e.g.
    /// "⌘C×12, ⌘V×12, Tab×40, ↵×6". Structure only, no content.
    var shortcuts: String = ""
    /// Fields typed into during the span, with an optional Deep-mode class, e.g.
    /// "Invoice Number [identifier], Amount [currency]". Labels are on-screen UI
    /// text; classes are derived from those labels, never from typed characters.
    var fields: String = ""

    var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Keys+clicks per active minute — a proxy for active vs. passive work.
    var inputIntensity: Double {
        guard duration > 0 else { return 0 }
        return Double(keystrokes + clicks) / (duration / 60)
    }
}

/// How the screen-capture capability behaves.
enum ScreenshotMode: String, CaseIterable, Identifiable, Equatable {
    case off
    /// Store a locally-redacted (blurred) thumbnail, auto-deleted after 24h.
    case thumbnails
    /// Interpret each frame with a LOCAL vision model into a one-line narrative,
    /// store only that text, and delete the image immediately. No pixels persist.
    case storyline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .thumbnails: return "Thumbnails"
        case .storyline: return "Storyline"
        }
    }

    var blurb: String {
        switch self {
        case .off:
            return "No screen capture."
        case .thumbnails:
            return "Occasional captures. Each one is shrunk and blurred on this Mac before it is saved, then deleted after 24 hours."
        case .storyline:
            return "A local vision model reads each capture and writes one line about the task. The image is deleted straight away and only the line is kept. Nothing leaves this Mac."
        }
    }
}

/// How much detail the local vision model reports from each frame. This is the
/// depth-vs-privacy dial: "activity" describes the task without content; "detailed"
/// reads what's actually on screen (text, form values, AI questions) for a much
/// richer, automation-grade story — at the cost of storing more sensitive content.
enum CaptureDepth: String, CaseIterable, Identifiable, Equatable {
    case activity
    case detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: return "Activity"
        case .detailed: return "Detailed"
        }
    }

    var blurb: String {
        switch self {
        case .activity:
            return "One line per moment describing the task. Names, numbers and emails are stripped out. Best for privacy."
        case .detailed:
            return "Reads what is on screen: the page, the form fields and their values, the questions asked of AI tools, the apparent goal. Much better for judging what can be automated. It also stores more sensitive content, so use it only with consent."
        }
    }
}

/// One redacted screen capture. The stored image is deliberately reduced/blurred
/// locally before it ever touches disk; the original full-resolution frame is
/// never persisted.
struct Screenshot: Identifiable, Equatable {
    var id: Int64 = 0
    var timestamp: Date
    var appName: String
    var windowTitle: String
    /// On-disk path of the redacted thumbnail.
    var path: String
    var isDemo: Bool = false
}

/// A stretch when the user was away from the keyboard (no hardware input).
/// Recorded so idle time is shown explicitly, never described as work.
struct IdleSession: Identifiable, Equatable {
    var id: Int64 = 0
    var start: Date
    var end: Date
    var isDemo: Bool = false

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// A fused summary of one calendar minute of work — combining the scene
/// narratives, apps/tabs, keystroke and click counts, shortcuts, and fields
/// captured in that minute into one description of what the person did.
struct MinuteSummary: Identifiable, Equatable {
    var id: Int64 = 0
    /// Start of the minute (floored to :00 seconds).
    var minuteStart: Date
    var text: String
    /// Comma-separated apps/tabs seen this minute.
    var apps: String
    var keystrokes: Int
    var clicks: Int
    var shortcuts: String
    var fields: String
    /// How many raw moments (scene narratives) fed this summary.
    var sourceCount: Int
    /// Task this minute belongs to, or 0 if not yet grouped.
    var taskID: Int64 = 0
    var isDemo: Bool = false
}

/// A higher-level story bundling consecutive same-task minutes into one task,
/// with the full context of what was done and a read on what's automatable.
struct TaskSummary: Identifiable, Equatable {
    var id: Int64 = 0
    var start: Date
    var end: Date
    var title: String
    var text: String
    var apps: String
    var minuteCount: Int
    /// Short automatable read, e.g. "High — repetitive copy/paste between systems".
    var automatable: String
    var isDemo: Bool = false

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// A one-line narrative produced locally from a screen frame, kept alongside the
/// image it was generated from so the user can review both. The image is stored
/// locally with a retention window and can be deleted at any time.
struct SceneNarrative: Identifiable, Equatable {
    var id: Int64 = 0
    var timestamp: Date
    var appName: String
    var windowTitle: String
    var text: String
    /// On-disk path of the captured frame (downscaled) this narrative describes.
    var imagePath: String = ""
    /// What triggered this capture — "Pasted", "Filled a field", "Switched to …",
    /// or "" for an interval sample.
    var trigger: String = ""
    var isDemo: Bool = false
}

/// Aggregated time for one application over a query range.
struct AppTotal: Identifiable, Equatable {
    var id: String { bundleID }
    var bundleID: String
    var appName: String
    var duration: TimeInterval
    var spanCount: Int
}

/// A group of spans that share a normalized window title — our proxy for a "task".
struct TaskGroup: Identifiable, Equatable {
    var id: String { appName + "|" + title }
    var title: String
    var appName: String
    var duration: TimeInterval
    var sessions: Int
    var lastSeen: Date
}

/// A task enriched with the actual on-screen content captured while it happened
/// — the detailed narratives (prompts, answers, form values) from the local
/// vision model, so you can see WHAT the work was, not just its window title.
struct DetailedTask: Identifiable, Equatable {
    var id: String
    var title: String
    var appUnit: String
    var duration: TimeInterval
    var sessions: Int
    var lastSeen: Date
    /// Detailed content moments captured during this task, time-ordered.
    var moments: [SceneNarrative]
    /// A short snippet for the collapsed row (from the richest moment).
    var preview: String
}

/// Time spent per hour-of-day, split by app, for the timeline chart.
struct HourlyActivity: Identifiable, Equatable {
    var id: String { "\(hour)|\(appName)" }
    var hour: Int
    var appName: String
    var duration: TimeInterval
}

/// Time observed per calendar day, for the trend chart.
struct DailyTotal: Identifiable, Equatable {
    var id: Date { day }
    var day: Date
    var duration: TimeInterval
}

/// A repeated cross-app sequence detected by the pattern miner —
/// a candidate workflow that could be automated.
/// One movement of data between two contexts: a copy or cut in one place followed
/// within a short window by a paste somewhere else. This is the primary evidence
/// of a mechanical chore, and it is structure only: which app and window the data
/// left, which app, window and field it landed in, and how long that took. Never
/// what was copied.
struct Transfer: Identifiable, Equatable {
    var id: Int64 = 0
    /// Moment of the paste.
    var at: Date
    var fromBundleID: String
    var fromApp: String
    /// Workflow unit of the source (site for browsers, app otherwise).
    var fromUnit: String
    var fromTitle: String
    var toBundleID: String
    var toApp: String
    var toUnit: String
    var toTitle: String
    /// On-screen label of the field pasted into, "" if none was in focus.
    var toField: String
    /// Seconds between the copy and the paste.
    var gapSeconds: TimeInterval
    var isDemo: Bool = false

    /// "Excel → NetSuite", the hop this transfer represents.
    var hop: String { "\(fromUnit) → \(toUnit)" }
}

struct WorkflowPattern: Identifiable, Equatable {
    var id: String { apps.joined(separator: ">") }
    /// Ordered app names forming the repeated sequence, e.g. ["Mail", "Preview", "Excel", "Chrome"].
    var apps: [String]
    /// Number of times the sequence was observed.
    var occurrences: Int
    /// Median active time of one occurrence.
    var medianDuration: TimeInterval
    /// Total active time across all occurrences in the observed window.
    var totalDuration: TimeInterval
    /// Number of days the source data covers (for extrapolation).
    var daysObserved: Int
    /// Heuristic 0–100 score of how automatable this looks.
    var automationScore: Int
    /// Representative window titles seen inside occurrences, for context.
    var sampleTitles: [String]
    /// Wall-clock windows of each occurrence — used to pull the screenshots,
    /// narratives, and spans for the drill-down detail view.
    var windows: [DateInterval] = []
    /// The most representative window title for each app step, in order — a
    /// clearer "what happened at each step" than the bare app names.
    var stepLabels: [String] = []

    /// Where the pattern came from. Transfer-derived patterns are built from
    /// copy-and-paste movements between contexts and are the primary evidence;
    /// sequence-derived ones come from repeated window orders and are weaker.
    enum Source: String, Equatable { case transfers, sequence }
    var source: Source = .sequence
    /// Field labels pasted or typed into on at least half the runs.
    var fields: [String] = []
    /// Cross-context copy-and-paste movements across all occurrences.
    var transferCount: Int = 0
    /// The shared automation judgement, when it has been computed.
    var verdict: Verdict? = nil

    /// A single (possibly partial) observed day is too thin to annualize —
    /// the UI shows projections only when this is true.
    var projectionIsReliable: Bool { daysObserved >= 2 }

    /// Extrapolated hours per year, assuming the observed window is representative.
    /// daysObserved counts working days, matching the 260-workday multiplier.
    var estimatedHoursPerYear: Double {
        guard daysObserved > 0 else { return 0 }
        let perDay = totalDuration / Double(daysObserved)
        return perDay * 260 / 3600 // 260 working days
    }

    /// Extrapolated yearly labour cost that automation could recover.
    func estimatedYearlySaving(hourlyRate: Double) -> Double {
        // Assume automation recovers a fraction of the time proportional to the score,
        // capped at 85% — some human review always remains.
        let recoverable = min(0.85, Double(automationScore) / 100.0)
        return estimatedHoursPerYear * hourlyRate * recoverable
    }
}

/// Query window used across the dashboard.
enum TimeRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "7 Days"
    case twoWeeks = "14 Days"

    var id: String { rawValue }

    var days: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .twoWeeks: return 14
        }
    }

    /// Start of the range, anchored to local midnight.
    func startDate(now: Date = Date()) -> Date {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        if self == .today { return todayStart }
        return cal.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
    }
}
