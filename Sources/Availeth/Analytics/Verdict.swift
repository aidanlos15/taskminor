import Foundation

/// What the evidence for one candidate workflow looks like, gathered the same way
/// whether the candidate came from transfers or from a repeated window sequence.
struct Evidence: Equatable {
    /// Separate runs of the same shape.
    var occurrences: Int
    /// Distinct working days those runs fell on.
    var daysObserved: Int
    /// Active time of each run.
    var durations: [TimeInterval]
    /// Copy-in-one-context, paste-in-another events across all runs.
    var transfers: Int
    /// Field labels present on at least half the runs.
    var consistentFields: [String]
    var keystrokes: Int
    var clicks: Int
    /// Context switches across all runs (window changes).
    var switches: Int
    /// Time spent in windows with no keys and no clicks at all.
    var readingSeconds: TimeInterval
    var totalSeconds: TimeInterval

    static let empty = Evidence(occurrences: 0, daysObserved: 0, durations: [], transfers: 0, consistentFields: [],
                                keystrokes: 0, clicks: 0, switches: 0, readingSeconds: 0, totalSeconds: 0)
}

/// The one automation judgement in the app. The Workflows tab and the Story
/// cards both use it, so they cannot disagree about the same work.
///
/// It is evidence-gated: until a shape has recurred enough it says so instead of
/// guessing. Then it scores repetition, regularity and how mechanical the work
/// was, and it subtracts for the things that look like a chore but are not:
/// long stretches of composing text, reading, and bouncing between windows
/// without doing anything in them.
struct Verdict: Equatable {
    enum Level: String, Equatable {
        case insufficient = "Not enough evidence yet"
        case low = "Low"
        case medium = "Medium"
        case high = "High"
    }

    static let minOccurrences = 5
    static let minDays = 2

    var level: Level
    var score: Int
    /// What supports the verdict.
    var reasons: [String]
    /// What argues against it, kept apart so a card never reads as if "mostly
    /// reading" were evidence FOR automating something.
    var caveats: [String] = []

    /// True only for Medium and High. Insufficient is never a candidate.
    var isCandidate: Bool { level == .medium || level == .high }

    /// The line shown on cards: "High — repeated copy/paste between systems, same fields each run".
    var display: String {
        var out = level.rawValue
        if !reasons.isEmpty { out += " — " + reasons.joined(separator: ", ") }
        if !caveats.isEmpty { out += ", though " + caveats.joined(separator: " and ") }
        return out
    }

    static func assess(_ e: Evidence) -> Verdict {
        if e.occurrences < minOccurrences || e.daysObserved < minDays {
            let seen = e.occurrences == 0
                ? "not seen to repeat yet"
                : "seen \(e.occurrences) time\(e.occurrences == 1 ? "" : "s") on \(e.daysObserved) day\(e.daysObserved == 1 ? "" : "s")"
            return Verdict(level: .insufficient, score: 0,
                           reasons: ["\(seen), needs \(minOccurrences) across \(minDays) days"])
        }

        let runs = Double(e.occurrences)
        let transfersPerRun = Double(e.transfers) / runs
        let keysPerRun = Double(e.keystrokes) / runs
        let minutes = max(1, e.totalSeconds / 60)
        let inputPerMinute = Double(e.keystrokes + e.clicks) / minutes
        let switchRate = Double(e.switches) / minutes
        let readingFraction = e.totalSeconds > 0 ? e.readingSeconds / e.totalSeconds : 0

        // Regularity: 1 when every run takes the same time, 0 when they vary wildly.
        var regularity = 0.0
        if e.durations.count >= 2 {
            let mean = e.durations.reduce(0, +) / Double(e.durations.count)
            let variance = e.durations.reduce(0) { $0 + pow($1 - mean, 2) } / Double(e.durations.count)
            let cv = mean > 0 ? sqrt(variance) / mean : 1
            regularity = max(0, min(1, 1 - cv))
        }

        // Mechanical evidence is a precondition, not one ingredient among many.
        // Something can recur twenty times, take exactly the same length every
        // time, and still be a habit rather than a chore: checking email between
        // edits does all of that. Unless data actually moved between contexts, or
        // the same fields were filled run after run, there is nothing for an
        // automation to take over, so regularity and frequency cannot on their own
        // lift a candidate above Low. (This exact case reached Medium on
        // "takes about the same time every run" until a test caught it.)
        let hasMechanicalEvidence = transfersPerRun >= 0.5 || !e.consistentFields.isEmpty

        var score = 0.0
        var reasons: [String] = []
        var caveats: [String] = []

        // Positive evidence.
        if transfersPerRun >= 0.5 {
            score += 40 * min(1, transfersPerRun / 2)
            reasons.append(transfersPerRun >= 2 ? "repeated copy/paste between systems" : "data copied between systems")
        }
        if !e.consistentFields.isEmpty {
            score += 25 * min(1, Double(e.consistentFields.count) / 3)
            reasons.append("same fields filled each run")
        }
        if regularity >= 0.5 {
            score += 20 * regularity
            reasons.append("takes about the same time every run")
        }
        score += 15 * min(1, Double(e.occurrences - minOccurrences) / 15)

        // Negative evidence: things that look busy but are not chores.
        if readingFraction > 0.6 {
            score -= 25; caveats.append("much of it is reading")
        }
        if keysPerRun > 300 && transfersPerRun < 0.5 && e.consistentFields.isEmpty {
            score -= 25; caveats.append("much of it is composing text")
        }
        if switchRate > 3 && inputPerMinute < 20 {
            score -= 20; caveats.append("there is a lot of switching without much being done")
        }

        let clamped = Int(max(0, min(100, score.rounded())))
        var level: Level = clamped >= 60 ? .high : (clamped >= 35 ? .medium : .low)
        if !hasMechanicalEvidence {
            level = .low
            reasons = ["no data moved between systems and no forms filled repeatedly"]
            caveats = []
        }
        if reasons.isEmpty { reasons.append(level == .low ? "no data moved and no forms filled" : "repetitive interactions") }
        return Verdict(level: level, score: hasMechanicalEvidence ? clamped : min(clamped, 34), reasons: reasons, caveats: caveats)
    }
}
