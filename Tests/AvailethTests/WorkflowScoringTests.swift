import XCTest
@testable import Availeth

/// The automation score is structure (miner) + evidence (insight builder), and
/// every automatable workflow is priced — even from a single observed day.
final class WorkflowScoringTests: XCTestCase {

    func testEvidenceLiftsScoreAndCognitiveWorkIsCapped() {
        typealias E = WorkflowInsighter.Evidence
        let transfer = E(text: "", automatable: true, crossAppTransfer: true, consistentFields: [], cognitive: nil)
        XCTAssertEqual(WorkflowInsighter.finalScore(base: 45, evidence: transfer), 75)
        let both = E(text: "", automatable: true, crossAppTransfer: true, consistentFields: ["Invoice Number", "Amount"], cognitive: nil)
        XCTAssertEqual(WorkflowInsighter.finalScore(base: 45, evidence: both), 87)
        let fieldsOnly = E(text: "", automatable: true, crossAppTransfer: false, consistentFields: ["Amount"], cognitive: nil)
        XCTAssertEqual(WorkflowInsighter.finalScore(base: 50, evidence: fieldsOnly), 60)
        let thinking = E(text: "", automatable: false, crossAppTransfer: false, consistentFields: [], cognitive: "reading and analysis")
        XCTAssertEqual(WorkflowInsighter.finalScore(base: 55, evidence: thinking), 35, "capped at 45, then 10 off for thinking work")
        let navigation = E(text: "", automatable: false, crossAppTransfer: false, consistentFields: [], cognitive: nil)
        XCTAssertEqual(WorkflowInsighter.finalScore(base: 30, evidence: navigation), 30)
        XCTAssertLessThanOrEqual(WorkflowInsighter.finalScore(base: 55, evidence: both), 98)
    }

    func testStructuralScoreSaturatesAtEightRunsAndCapsAt55() {
        let ten = PatternMiner.score(apps: ["Notes", "Excel", "Notes", "Excel"], durations: Array(repeating: 60, count: 10))
        let eight = PatternMiner.score(apps: ["Notes", "Excel", "Notes", "Excel"], durations: Array(repeating: 60, count: 8))
        XCTAssertEqual(ten, eight, "repetition saturates at eight runs")
        XCTAssertLessThanOrEqual(ten, 55)
        let uneven = PatternMiner.score(apps: ["Notes", "Excel", "Notes", "Excel"], durations: [40, 90, 55, 120, 48, 70, 65, 100, 52, 80])
        XCTAssertGreaterThanOrEqual(uneven, 40, "uneven pacing costs at most ten points")
    }

    /// Ten copy/paste runs between Notes and Excel, all on one day: scores as a
    /// strong candidate and carries a yearly figure.
    func testTenRunCopyPasteLoopScoresHighAndIsPricedFromOneDay() {
        let store = Store.inMemory()
        let base = Date().addingTimeInterval(-3 * 3600)
        var windows: [DateInterval] = []
        var durations: [TimeInterval] = []
        for i in 0..<10 {
            let t = base.addingTimeInterval(Double(i) * 120)
            let j = Double(i % 3) * 8
            store.insert(ActivitySpan(bundleID: "com.apple.Notes", appName: "Notes", windowTitle: "Invoices to enter", start: t, end: t.addingTimeInterval(15 + j), keystrokes: 4, clicks: 3, shortcuts: "⌘C×3"))
            store.insert(ActivitySpan(bundleID: "com.microsoft.Excel", appName: "Microsoft Excel", windowTitle: "Supplier Invoices.xlsx", start: t.addingTimeInterval(16 + j), end: t.addingTimeInterval(40 + j), keystrokes: 20, clicks: 6, shortcuts: "⌘V×3, Tab×4"))
            store.insert(ActivitySpan(bundleID: "com.apple.Notes", appName: "Notes", windowTitle: "Invoices to enter", start: t.addingTimeInterval(41 + j), end: t.addingTimeInterval(50 + j), shortcuts: "⌘C×1"))
            store.insert(ActivitySpan(bundleID: "com.microsoft.Excel", appName: "Microsoft Excel", windowTitle: "Supplier Invoices.xlsx", start: t.addingTimeInterval(51 + j), end: t.addingTimeInterval(60 + j), shortcuts: "⌘V×1, ⌘S×1"))
            windows.append(DateInterval(start: t, end: t.addingTimeInterval(60 + j)))
            durations.append(58 + j)
        }
        let apps = ["Notes", "Excel", "Notes", "Excel"]
        let structural = PatternMiner.score(apps: apps, durations: durations)
        let pattern = WorkflowPattern(apps: apps, occurrences: 10, medianDuration: 60, totalDuration: 600, daysObserved: 1,
                                      automationScore: structural, sampleTitles: [], windows: windows,
                                      stepLabels: ["Invoices to enter", "Supplier Invoices.xlsx", "Invoices to enter", "Supplier Invoices.xlsx"])
        let insight = WorkflowInsighter.build(pattern, store: store, demo: false)
        XCTAssertTrue(insight.automatable)
        XCTAssertGreaterThanOrEqual(insight.pattern.automationScore, 70, "ten copy/paste runs between two systems is a strong candidate (got \(insight.pattern.automationScore))")
        XCTAssertGreaterThan(insight.pattern.estimatedYearlySaving(hourlyRate: 45), 0, "priced even from a single observed day")
        XCTAssertTrue(insight.whatToAutomate.contains("a year."), "the hours line is stated plainly; the basis sits under the price")
        XCTAssertEqual(insight.pattern.projectionBasis, "projected from one observed day")
    }

    func testWhatItIsUsesFirstSentences() {
        let moments = [
            SceneNarrative(timestamp: Date(), appName: "Notes", windowTitle: "", text: "The user opened the invoice list. The window shows folders on the left and a long description that goes on."),
            SceneNarrative(timestamp: Date(), appName: "Excel", windowTitle: "", text: "The user pasted a supplier name into the sheet. More detail follows."),
        ]
        let pattern = WorkflowPattern(apps: ["Notes", "Excel", "Notes"], occurrences: 3, medianDuration: 60, totalDuration: 180, daysObserved: 1,
                                      automationScore: 40, sampleTitles: [], windows: [], stepLabels: [])
        XCTAssertEqual(WorkflowInsighter.deriveWhatItIs(pattern: pattern, moments: moments, steps: []),
                       "The user opened the invoice list. → The user pasted a supplier name into the sheet.")
    }
}

extension WorkflowScoringTests {
    func testChordCountsParse() {
        XCTAssertEqual(WorkflowInsighter.chordCounts("⌘C×12, ⌘V×12, Tab×40, ↵×6"), ["⌘C": 12, "⌘V": 12, "Tab": 40, "↵": 6])
        XCTAssertEqual(WorkflowInsighter.chordCounts("⌘S"), ["⌘S": 1])
        XCTAssertEqual(WorkflowInsighter.chordCounts(""), [:])
        XCTAssertNil(WorkflowInsighter.chordCounts("⇧⌘C×3")["⌘C"], "a different chord is not a copy")
    }

    /// An incidental ⌘C in the destination never cancels the source's copies,
    /// and the verdict does not depend on app-name order.
    func testTransferSurvivesCopiesInTheDestination() {
        func spans(_ src: String, _ dst: String, runs: Int = 10) -> [ActivitySpan] {
            (0..<runs).flatMap { _ -> [ActivitySpan] in [
                ActivitySpan(bundleID: "a", appName: src, windowTitle: "List", start: Date(), end: Date(), shortcuts: "⌘C×3"),
                ActivitySpan(bundleID: "b", appName: dst, windowTitle: "Sheet", start: Date(), end: Date(), shortcuts: "⌘V×3, ⌘C×1"),
            ] }
        }
        let t1 = WorkflowInsighter.crossAppTransfer(spans("Notes", "Microsoft Excel"))
        XCTAssertEqual(t1?.from, "Notes"); XCTAssertEqual(t1?.to, "Excel")
        let t2 = WorkflowInsighter.crossAppTransfer(spans("Microsoft Word", "Notes"))
        XCTAssertEqual(t2?.from, "Word"); XCTAssertEqual(t2?.to, "Notes")
        // Rearranging within one sheet is not a transfer.
        let within = [ActivitySpan(bundleID: "b", appName: "Microsoft Excel", windowTitle: "Sheet", start: Date(), end: Date(), shortcuts: "⌘C×20, ⌘V×20"),
                      ActivitySpan(bundleID: "a", appName: "Notes", windowTitle: "List", start: Date(), end: Date(), shortcuts: "⌘C×3")]
        XCTAssertNil(WorkflowInsighter.crossAppTransfer(within))
        // A single stray paste is not a habit.
        let stray = [ActivitySpan(bundleID: "a", appName: "Notes", windowTitle: "", start: Date(), end: Date(), shortcuts: "⌘C×5"),
                     ActivitySpan(bundleID: "b", appName: "Microsoft Excel", windowTitle: "", start: Date(), end: Date(), shortcuts: "⌘V×1")]
        XCTAssertNil(WorkflowInsighter.crossAppTransfer(stray))
    }

    func testSearchBoxAloneIsNotFormEntry() {
        XCTAssertNil(WorkflowInsighter.cleanFieldName("PO Search [search]"))
        XCTAssertNil(WorkflowInsighter.cleanFieldName("Find in page"))
        XCTAssertEqual(WorkflowInsighter.cleanFieldName("Invoice Number [identifier]"), "Invoice Number")
        let pattern = WorkflowPattern(apps: ["Chrome", "Excel", "Chrome"], occurrences: 4, medianDuration: 30, totalDuration: 120, daysObserved: 1,
                                      automationScore: 40, sampleTitles: [], windows: [], stepLabels: [])
        let lookups: [[ActivitySpan]] = (0..<4).map { _ in
            [ActivitySpan(bundleID: "c", appName: "Google Chrome", windowTitle: "Orders - NetSuite", start: Date(), end: Date(), fields: "Search [search]")]
        }
        let e = WorkflowInsighter.assessAutomation(pattern: pattern, occSpans: lookups, narratives: [])
        XCTAssertFalse(e.automatable, "a look-up loop with only a search box is not data entry")
        let oneField: [[ActivitySpan]] = (0..<4).map { _ in
            [ActivitySpan(bundleID: "c", appName: "Google Chrome", windowTitle: "Bill - NetSuite", start: Date(), end: Date(), shortcuts: "Tab×3, ↵×1", fields: "Amount [currency]")]
        }
        XCTAssertTrue(WorkflowInsighter.assessAutomation(pattern: pattern, occSpans: oneField, narratives: []).automatable, "one real field committed on every run counts")
    }

    func testAppMixUsesUnitLabels() {
        let d = Array(repeating: 60.0, count: 8)
        XCTAssertEqual(PatternMiner.score(apps: ["Chrome", "Excel", "Chrome"], durations: d),
                       PatternMiner.score(apps: ["Google Chrome", "Microsoft Excel", "Google Chrome"], durations: d))
        XCTAssertGreaterThan(PatternMiner.score(apps: ["Gmail", "Google Sheets", "Gmail"], durations: d),
                             PatternMiner.score(apps: ["Foo", "Bar", "Foo"], durations: d))
    }
}
