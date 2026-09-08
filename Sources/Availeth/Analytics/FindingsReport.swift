import Foundation

/// What Availeth is allowed to see, and nothing else.
///
/// The app's whole design keeps activity on the Mac, but Availeth's business is
/// to build the automation it finds, and until now the only way to learn what was
/// found was to stand behind the employee. This is the deliberate, consented way
/// out: workflow-level aggregates only, shown to the person in full before it
/// leaves, saved to a file they send themselves. Nothing is uploaded by the app.
///
/// Excluded on purpose:
/// - Window titles. "Invoice #10247 — Acme Corp" names a customer.
/// - Document paths, screenshots, scene narratives, minute and task stories.
/// - Anything typed. Field LABELS are included ("Amount"); values never are.
struct FindingsReport: Equatable, Identifiable {
    var id: Date { generatedAt }

    struct Finding: Equatable {
        /// The systems the work passes through, e.g. ["Microsoft Excel", "NetSuite"].
        var systems: [String]
        var occurrences: Int
        var daysObserved: Int
        var medianSeconds: Int
        var transfers: Int
        /// Field labels filled on most runs. Labels only, never values.
        var fields: [String]
        var verdict: String
        var estimatedHoursPerYear: Int
    }

    var generatedAt: Date
    var daysOfCapture: Int
    var totalObservedMinutes: Int
    var findings: [Finding]

    /// Only genuine candidates are worth sending; the rest is noise.
    static func build(from insights: [WorkflowInsight], spans: [ActivitySpan], now: Date = Date()) -> FindingsReport {
        let candidates = insights.filter { $0.pattern.verdict?.isCandidate == true }
        return FindingsReport(
            generatedAt: now,
            daysOfCapture: Analytics.workdaysObserved(spans),
            totalObservedMinutes: Int(spans.reduce(0.0) { $0 + $1.duration } / 60),
            findings: candidates.map { i in
                Finding(
                    systems: i.pattern.apps,
                    occurrences: i.pattern.occurrences,
                    daysObserved: i.pattern.daysObserved,
                    medianSeconds: Int(i.pattern.medianDuration),
                    transfers: i.pattern.transferCount,
                    fields: i.pattern.fields,
                    verdict: i.pattern.verdict?.display ?? "",
                    estimatedHoursPerYear: i.pattern.projectionIsReliable ? Int(i.pattern.estimatedHoursPerYear) : 0
                )
            }
        )
    }

    /// The exact text that gets saved. Shown to the person first, unchanged.
    var text: String {
        let df = DateFormatter()
        df.dateFormat = "d MMMM yyyy"
        var out = """
        Availeth findings
        Prepared \(df.string(from: generatedAt))

        Watched \(daysOfCapture) working day\(daysOfCapture == 1 ? "" : "s"), \(totalObservedMinutes) minutes of activity.

        This file contains only the summary below. It has no window titles, no file
        names, no screenshots and nothing that was typed. Field names are the labels
        on the form, never their contents.

        """
        if findings.isEmpty {
            out += """

            No automation candidates yet.

            Availeth waits until the same work has been seen \(Verdict.minOccurrences) times across
            \(Verdict.minDays) separate days before calling it a candidate, so a busy hour is never
            mistaken for a routine. Leave it running for a few more days.
            """
            return out
        }
        for (i, f) in findings.enumerated() {
            out += "\n\(i + 1). \(f.systems.joined(separator: " → "))\n"
            out += "   Seen \(f.occurrences) times across \(f.daysObserved) days, typically \(Format.preciseDuration(Double(f.medianSeconds))) each.\n"
            if f.transfers > 0 { out += "   \(f.transfers) copy-and-paste movements between these systems.\n" }
            if !f.fields.isEmpty { out += "   Fields filled each run: \(f.fields.joined(separator: ", ")).\n" }
            if f.estimatedHoursPerYear > 0 { out += "   About \(f.estimatedHoursPerYear) hours a year at this rate.\n" }
            out += "   Assessment: \(f.verdict)\n"
        }
        return out
    }
}
