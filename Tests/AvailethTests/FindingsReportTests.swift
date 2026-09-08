import XCTest
@testable import Availeth

/// The report is the one thing that leaves the Mac, so what it cannot contain
/// matters more than what it can. These are the tests that make the promise on
/// the sheet ("no window titles, nothing you typed") checkable rather than a
/// claim in the interface.
final class FindingsReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Window titles here name a real customer and a real person, exactly the
    /// sort of thing that must never reach Availeth.
    private func sensitiveInsight(automatable: Bool) -> WorkflowInsight {
        var p = WorkflowPattern(
            apps: ["Microsoft Excel", "NetSuite"],
            occurrences: 12, medianDuration: 240, totalDuration: 2880, daysObserved: 4,
            automationScore: 70,
            sampleTitles: ["Invoice #10247 — Acme Corp", "Purchase Orders.xlsx", "Beata Kowalski payroll"],
            windows: [DateInterval(start: now, duration: 240)],
            stepLabels: ["Invoice #10247 — Acme Corp", "Vendor Bills — NetSuite"],
            source: .transfers, fields: ["Invoice Number", "Amount"], transferCount: 30
        )
        p.verdict = Verdict(level: automatable ? .high : .low, score: automatable ? 70 : 10,
                            reasons: ["repeated copy/paste between systems"])
        return WorkflowInsight(
            pattern: p,
            title: "Invoice #10247 — Acme Corp entry",
            whatItIs: "Copying from Purchase Orders.xlsx for Acme Corp",
            whatToAutomate: "Data is carried from Microsoft Excel into NetSuite by hand.",
            automatable: automatable,
            moments: [SceneNarrative(timestamp: now, appName: "Google Chrome",
                                     windowTitle: "Vendor Bills — NetSuite",
                                     text: "Entering invoice 10247 for Acme Corp, amount 4,182.50")],
            steps: []
        )
    }

    private var spans: [ActivitySpan] {
        [ActivitySpan(bundleID: "com.microsoft.Excel", appName: "Microsoft Excel",
                      windowTitle: "Purchase Orders.xlsx — Acme Corp",
                      start: now, end: now.addingTimeInterval(600), isDemo: false,
                      keystrokes: 200, clicks: 30, documentPath: "/Users/beata/Finance/Acme.xlsx")]
    }

    func testReportCarriesNoTitlesPathsOrNarratives() {
        let report = FindingsReport.build(from: [sensitiveInsight(automatable: true)], spans: spans, now: now)
        let text = report.text
        for leak in ["Acme", "10247", "Purchase Orders.xlsx", "Beata", "Kowalski", "/Users/", "4,182.50", "Vendor Bills"] {
            XCTAssertFalse(text.contains(leak), "report leaked \(leak):\n\(text)")
        }
    }

    /// The parts Availeth genuinely needs are all present.
    func testReportCarriesTheEvidenceAvailethNeeds() {
        let report = FindingsReport.build(from: [sensitiveInsight(automatable: true)], spans: spans, now: now)
        let text = report.text
        XCTAssertTrue(text.contains("Microsoft Excel → NetSuite"), text)
        XCTAssertTrue(text.contains("12 times across 4 days"), text)
        XCTAssertTrue(text.contains("Invoice Number, Amount"), text)
        XCTAssertTrue(text.contains("30 copy-and-paste"), text)
    }

    /// Field LABELS are allowed; a value that leaked into a label is not the
    /// report's job to catch, but the label list must be exactly what was stored.
    func testOnlyCandidatesAreIncluded() {
        let report = FindingsReport.build(from: [sensitiveInsight(automatable: false)], spans: spans, now: now)
        XCTAssertTrue(report.findings.isEmpty, "work that is not a candidate is not sent")
        XCTAssertTrue(report.text.contains("No automation candidates yet"), report.text)
    }

    func testEmptyReportExplainsTheEvidenceGate() {
        let report = FindingsReport.build(from: [], spans: spans, now: now)
        XCTAssertTrue(report.text.contains("\(Verdict.minOccurrences) times"), report.text)
        XCTAssertTrue(report.text.contains("\(Verdict.minDays) separate days"), report.text)
    }
}
