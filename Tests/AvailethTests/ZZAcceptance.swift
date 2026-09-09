import XCTest
@testable import Availeth

/// The product's own claim, tested end to end.
final class ZZAcceptance: XCTestCase {
    /// The sample dataset must yield the invoice loop as a genuine candidate.
    func testSampleDataFindsTheInvoiceLoop() {
        let store = Store.inMemory()
        store.insertBatch(DemoData.generate())
        DemoData.generateTransfers().forEach { store.insert(transfer: $0) }
        let spans = store.spans(from: .distantPast, to: .distantFuture, demo: true)
        let transfers = store.transfers(from: .distantPast, to: .distantFuture, demo: true)
        let patterns = TransferMiner.mine(transfers: transfers, spans: spans)
        print("\n#### SAMPLE DATA")
        for p in patterns.prefix(5) {
            print("  \(p.occurrences)x over \(TransferMiner.distinctDays(p.windows.map(\.end)))d | \(p.apps.joined(separator: " > ")) | \(p.verdict?.display ?? "-") | fields: \(p.fields.joined(separator: ", "))")
        }
        let candidates = patterns.filter { $0.verdict?.isCandidate == true }
        XCTAssertFalse(candidates.isEmpty, "the sample must produce at least one real candidate")
        let names = candidates.flatMap(\.apps)
        XCTAssertTrue(names.contains("NetSuite"), "the invoice loop must be found: \(names)")
    }

    /// A developer's afternoon: constant switching, plenty of typing, nothing
    /// moved between systems. Must produce no candidates at all.
    func testDeveloperAfternoonProducesNoCandidates() {
        let store = Store.inMemory()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var spans: [ActivitySpan] = []
        for day in 0..<5 {
            for i in 0..<40 {
                let t = base.addingTimeInterval(Double(day) * 86400 + Double(i) * 180)
                let apps = [("Code", "project.swift"), ("Microsoft Outlook", "Inbox"), ("Safari", "docs")]
                let (app, title) = apps[i % 3]
                spans.append(ActivitySpan(bundleID: "x.\(app)", appName: app, windowTitle: title,
                                          start: t, end: t.addingTimeInterval(120), isDemo: false,
                                          keystrokes: app == "Code" ? 220 : 8, clicks: 6,
                                          shortcuts: "⌫×14, ↵×6", fields: ""))
            }
        }
        store.insertBatch(spans)
        let all = store.spans(from: .distantPast, to: .distantFuture, demo: false)
        let byTransfer = TransferMiner.mine(transfers: [], spans: all)
        let bySequence = PatternMiner.mine(spans: all)
        let insights = (byTransfer + bySequence).map { WorkflowInsighter.build($0, store: store, demo: false) }
        print("\n#### DEVELOPER AFTERNOON: \(insights.count) patterns")
        for i in insights.prefix(6) { print("  \(i.pattern.occurrences)x | \(i.pattern.apps.joined(separator: " > ")) | \(i.pattern.verdict?.display ?? "-")") }
        print("####\n")
        XCTAssertTrue(insights.allSatisfy { !$0.automatable },
                      "a developer switching windows must never read as automatable: \(insights.filter(\.automatable).map(\.pattern.apps))")
    }
}
