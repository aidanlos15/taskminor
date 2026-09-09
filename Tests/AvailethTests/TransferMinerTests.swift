import XCTest
@testable import Availeth

/// The transfer miner and the shared verdict are the change that decides whether
/// the product can tell a chore from a habit. These pin that.
final class TransferMinerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func transfer(_ dayOffset: Int, _ minuteOffset: Double,
                          from: (String, String), to: (String, String), field: String) -> Transfer {
        let at = base.addingTimeInterval(Double(dayOffset) * 86400 + minuteOffset * 60)
        return Transfer(at: at,
                        fromBundleID: "x.\(from.0)", fromApp: from.0, fromUnit: from.0, fromTitle: from.1,
                        toBundleID: "x.\(to.0)", toApp: to.0, toUnit: to.0, toTitle: to.1,
                        toField: field, gapSeconds: 8)
    }

    private func span(_ dayOffset: Int, _ minuteOffset: Double, app: String, title: String,
                      seconds: Double = 120, keys: Int = 40, clicks: Int = 6, fields: String = "") -> ActivitySpan {
        let start = base.addingTimeInterval(Double(dayOffset) * 86400 + minuteOffset * 60)
        return ActivitySpan(bundleID: "x.\(app)", appName: app, windowTitle: title,
                            start: start, end: start.addingTimeInterval(seconds), isDemo: false,
                            keystrokes: keys, clicks: clicks, shortcuts: "⌘C×1, ⌘V×2, Tab×3", fields: fields)
    }

    /// An invoice loop run six times over three days: Mail to Excel to NetSuite,
    /// the same fields each time. This is the case the whole product exists for.
    private func invoiceCorpus() -> (transfers: [Transfer], spans: [ActivitySpan]) {
        var t: [Transfer] = [], s: [ActivitySpan] = []
        for day in 0..<3 {
            for run in 0..<2 {
                let at = Double(run) * 90
                t.append(transfer(day, at, from: ("Mail", "Invoice #10247"), to: ("Excel", "Purchase Orders.xlsx"), field: "PO Search"))
                t.append(transfer(day, at + 1.5, from: ("Excel", "Purchase Orders.xlsx"), to: ("NetSuite", "Vendor Bills"), field: "Invoice Number [identifier]"))
                t.append(transfer(day, at + 2.5, from: ("Excel", "Purchase Orders.xlsx"), to: ("NetSuite", "Vendor Bills"), field: "Amount [currency]"))
                s.append(span(day, at - 1, app: "Mail", title: "Invoice #10247", fields: ""))
                s.append(span(day, at + 1, app: "Excel", title: "Purchase Orders.xlsx", fields: "PO Search [search]"))
                s.append(span(day, at + 2, app: "NetSuite", title: "Vendor Bills", fields: "Invoice Number [identifier], Amount [currency]"))
            }
        }
        return (t, s)
    }

    func testInvoiceLoopIsFoundAndJudgedAutomatable() {
        let (t, s) = invoiceCorpus()
        let patterns = TransferMiner.mine(transfers: t, spans: s)
        guard let top = patterns.first else { return XCTFail("no pattern found") }
        XCTAssertEqual(top.source, .transfers)
        XCTAssertEqual(top.occurrences, 6, "two runs a day over three days")
        XCTAssertTrue(top.apps.contains("Excel") && top.apps.contains("NetSuite"), "\(top.apps)")
        XCTAssertTrue(top.verdict?.isCandidate == true, top.verdict?.display ?? "no verdict")
        XCTAssertTrue(top.fields.contains("Invoice Number"), "\(top.fields)")
        XCTAssertTrue(top.fields.contains("Amount"), "\(top.fields)")
    }

    /// The same loop seen only twice is not yet a finding, however mechanical.
    func testTooFewRunsIsHonestlyInsufficient() {
        var (t, s) = invoiceCorpus()
        t = t.filter { $0.at < self.base.addingTimeInterval(86400) }
        s = s.filter { $0.start < self.base.addingTimeInterval(86400) }
        let patterns = TransferMiner.mine(transfers: t, spans: s)
        for p in patterns {
            XCTAssertEqual(p.verdict?.level, .insufficient, p.verdict?.display ?? "")
            XCTAssertFalse(p.verdict?.isCandidate ?? true)
        }
    }

    /// A paste inside the same window is editing, not a transfer between systems.
    func testSameUnitTransfersAreNotCrossSystemEvidence() {
        var t: [Transfer] = []
        for day in 0..<4 {
            for run in 0..<3 {
                t.append(transfer(day, Double(run) * 60, from: ("Excel", "Book1.xlsx"), to: ("Excel", "Book1.xlsx"), field: "B2"))
            }
        }
        let spans = (0..<4).flatMap { d in (0..<3).map { r in span(d, Double(r) * 60, app: "Excel", title: "Book1.xlsx") } }
        let patterns = TransferMiner.mine(transfers: t, spans: spans)
        for p in patterns {
            XCTAssertFalse(p.verdict?.level == .high, "same-window pastes must not read as High: \(p.verdict?.display ?? "")")
        }
    }

    func testEntriesSplitOnTheChainGap() {
        let t = [transfer(0, 0, from: ("A", "a"), to: ("B", "b"), field: ""),
                 transfer(0, 1, from: ("A", "a"), to: ("B", "b"), field: ""),
                 transfer(0, 30, from: ("A", "a"), to: ("B", "b"), field: "")]
        XCTAssertEqual(TransferMiner.entries(t).count, 2, "a 29-minute gap starts a new entry")
    }

    // MARK: - The verdict itself

    func testInsufficientBelowTheGate() {
        var e = Evidence.empty
        e.occurrences = 4; e.daysObserved = 3; e.transfers = 20
        XCTAssertEqual(Verdict.assess(e).level, .insufficient)
        e.occurrences = 9; e.daysObserved = 1
        XCTAssertEqual(Verdict.assess(e).level, .insufficient, "one day is never enough to annualize")
    }

    /// A developer bouncing between an editor and email: recurs constantly, moves
    /// nothing, fills nothing. This is the exact false positive that made every
    /// Story card read High before the change.
    func testFrequentContextSwitchingIsNotAutomatable() {
        let e = Evidence(occurrences: 20, daysObserved: 5, durations: Array(repeating: 120, count: 20),
                         transfers: 0, consistentFields: [], keystrokes: 900, clicks: 300,
                         switches: 160, readingSeconds: 900, totalSeconds: 2400)
        let v = Verdict.assess(e)
        XCTAssertEqual(v.level, .low, v.display)
        XCTAssertFalse(v.isCandidate)
    }

    /// Long unbroken typing with nothing moved is composition, not data entry.
    func testHeavyTypingWithoutTransfersIsNotAutomatable() {
        let e = Evidence(occurrences: 10, daysObserved: 4, durations: Array(repeating: 600, count: 10),
                         transfers: 0, consistentFields: [], keystrokes: 9000, clicks: 200,
                         switches: 12, readingSeconds: 200, totalSeconds: 6000)
        let v = Verdict.assess(e)
        XCTAssertFalse(v.isCandidate, v.display)
        XCTAssertEqual(v.level, .low, v.display)
    }

    func testMechanicalRecurringEntryIsHigh() {
        let e = Evidence(occurrences: 18, daysObserved: 6, durations: Array(repeating: 240, count: 18),
                         transfers: 40, consistentFields: ["Invoice Number", "Amount", "PO Number"],
                         keystrokes: 1600, clicks: 400, switches: 60, readingSeconds: 200, totalSeconds: 4320)
        let v = Verdict.assess(e)
        XCTAssertEqual(v.level, .high, v.display)
        XCTAssertTrue(v.isCandidate)
    }

    /// Field cleaning keeps real form fields and drops browser chrome.
    func testFieldCleaning() {
        XCTAssertEqual(Evidence.cleanField("Amount [currency]"), "Amount")
        XCTAssertNil(Evidence.cleanField("Search or enter website name"))
        XCTAssertNil(Evidence.cleanField("Save As:"))
        XCTAssertEqual(Evidence.cleanField("Invoice Number"), "Invoice Number")
    }

    // MARK: - Browser page identity

    func testPagePatternSeparatesSectionsAndDropsIdentifiers() {
        XCTAssertEqual(WorkflowUnit.pagePattern(URL(string: "https://secure.jobber.com/invoices/4821?tab=items")!), "secure.jobber.com/invoices/*")
        XCTAssertEqual(WorkflowUnit.pagePattern(URL(string: "https://secure.jobber.com/schedule")!), "secure.jobber.com/schedule")
        XCTAssertEqual(WorkflowUnit.pagePattern(URL(string: "https://www.example.com/")!), "example.com")
        XCTAssertNotEqual(WorkflowUnit.pagePattern(URL(string: "https://a.com/invoices/1")!),
                          WorkflowUnit.pagePattern(URL(string: "https://a.com/schedule/1")!))
    }
}
