import XCTest
@testable import Availeth

final class WorkflowInsightTests: XCTestCase {
    func testAlignedDemoWorkflowDetectedWithMoments() {
        let store = Store.inMemory()
        store.insertBatch(DemoData.generate())
        DemoData.generateNarratives().forEach { store.insertNarrative($0) }

        let spans = store.spans(from: .distantPast, to: .distantFuture, demo: true)
        let patterns = PatternMiner.mine(spans: spans)
        // The aligned invoice workflow surfaces with the browser tab as its
        // SITE ("NetSuite"), not "Chrome".
        let invoice = patterns.first { $0.apps.contains("Mail") && $0.apps.contains("Excel") && $0.apps.contains("NetSuite") }
        XCTAssertNotNil(invoice, "invoice workflow not detected: \(patterns.map(\.apps))")
        guard let invoice else { return }
        XCTAssertFalse(invoice.windows.isEmpty, "pattern has no occurrence windows")

        let insight = WorkflowInsighter.build(invoice, store: store, demo: true)
        XCTAssertFalse(insight.title.isEmpty)
        XCTAssertFalse(insight.whatItIs.isEmpty)
        XCTAssertFalse(insight.whatToAutomate.isEmpty)
        XCTAssertFalse(insight.steps.isEmpty)
        // The aligned narratives share timestamps with the workflow → moments present.
        XCTAssertFalse(insight.moments.isEmpty, "drill-down walkthrough is empty")

        // Copy/paste must be attributed to the ACTUAL units (Excel→NetSuite in
        // the demo), never the wrong first-two (Mail/Preview) or bare "Chrome".
        if insight.whatToAutomate.contains("move data from") {
            XCTAssertTrue(insight.whatToAutomate.contains("Excel") && insight.whatToAutomate.contains("NetSuite"),
                          "copy/paste mis-attributed: \(insight.whatToAutomate)")
            XCTAssertFalse(insight.whatToAutomate.contains("from Mail") || insight.whatToAutomate.contains("from Preview"))
        }

        // The moments must only contain THIS workflow's steps — no CRM/Salesforce
        // narrative leaking in from a concurrent workflow.
        for m in insight.moments {
            XCTAssertFalse(m.windowTitle.contains("Salesforce"), "foreign workflow leaked into moments: \(m.windowTitle)")
        }
        // Field-class tags must be stripped from user-facing prose.
        XCTAssertFalse(insight.whatToAutomate.contains("[identifier]"))
        XCTAssertFalse(insight.whatToAutomate.contains("[currency]"))
    }

    /// Step matching: a same-app window with a different title is excluded.
    func testStepMatchingExcludesForeignTitles() {
        let store = Store.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // A pattern whose Chrome step is "Vendor Bills — NetSuite".
        let spans = (0..<4).flatMap { i -> [ActivitySpan] in
            let base = now.addingTimeInterval(Double(i) * 600)
            return [
                ActivitySpan(bundleID: "com.apple.mail", appName: "Mail", windowTitle: "Invoice #\(i)", start: base, end: base.addingTimeInterval(30)),
                ActivitySpan(bundleID: "com.microsoft.Excel", appName: "Microsoft Excel", windowTitle: "Purchase Orders.xlsx", start: base.addingTimeInterval(35), end: base.addingTimeInterval(70), shortcuts: "⌘C×1"),
                ActivitySpan(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Vendor Bills — NetSuite", start: base.addingTimeInterval(75), end: base.addingTimeInterval(120), shortcuts: "⌘V×1"),
            ]
        }
        store.insertBatch(spans)
        // A Salesforce narrative sitting inside one occurrence window but NOT part of the steps.
        store.insertNarrative(SceneNarrative(timestamp: now.addingTimeInterval(50), appName: "Google Chrome", windowTitle: "Q3 Pipeline — Salesforce", text: "Updating a CRM opportunity."))
        store.insertNarrative(SceneNarrative(timestamp: now.addingTimeInterval(76), appName: "Google Chrome", windowTitle: "Vendor Bills — NetSuite", text: "Submitting a vendor bill."))

        // The Chrome/NetSuite tab surfaces as the "NetSuite" unit, not "Chrome".
        let pattern = PatternMiner.mine(spans: store.spans(from: .distantPast, to: .distantFuture, demo: false)).first { $0.apps.contains("NetSuite") }
        XCTAssertNotNil(pattern)
        let insight = WorkflowInsighter.build(pattern!, store: store, demo: false)
        // The Salesforce narrative must be excluded (different site); only NetSuite belongs.
        XCTAssertTrue(insight.moments.allSatisfy { !$0.windowTitle.contains("Salesforce") })
        // Copy in Excel, paste in NetSuite → correct unit attribution.
        XCTAssertTrue(insight.whatToAutomate.contains("Excel") && insight.whatToAutomate.contains("NetSuite"))
        XCTAssertTrue(insight.automatable)
    }

    /// Per-step detail must come ONLY from inside the workflow's own occurrences.
    /// Same-unit activity in the GAP between runs (a personal Excel sheet opened
    /// between invoice runs) must never leak into a step's account.
    func testStepContentExcludesGapContent() {
        let store = Store.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.insertBatch(invoiceRunSpans(now: now))
        // In-run Excel narrative (belongs to the Excel step; Excel span is 35–75s).
        store.insertNarrative(SceneNarrative(timestamp: now.addingTimeInterval(50), appName: "Microsoft Excel", windowTitle: "Purchase Orders.xlsx", text: "Copying invoice totals from the purchase orders sheet."))
        // GAP Excel narrative — same unit (Excel) but at now+300, well outside
        // every occurrence's padded window (runs at 0/600/1200/1800). Must NOT show.
        store.insertNarrative(SceneNarrative(timestamp: now.addingTimeInterval(300), appName: "Microsoft Excel", windowTitle: "Household Budget.xlsx", text: "Reviewing a personal household budget spreadsheet unrelated to work."))

        let pattern = PatternMiner.mine(spans: store.spans(from: .distantPast, to: .distantFuture, demo: false)).first { $0.apps.contains("NetSuite") && $0.apps.contains("Excel") }
        XCTAssertNotNil(pattern)
        let insight = WorkflowInsighter.build(pattern!, store: store, demo: false)
        let allContent = insight.steps.map(\.content).joined(separator: " ").lowercased()
        XCTAssertFalse(allContent.contains("household budget"), "gap content leaked into a step: \(allContent)")
        XCTAssertTrue(allContent.contains("purchase orders sheet") || allContent.contains("invoice totals"), "in-run Excel content missing: \(allContent)")
    }

    /// A repeated 3-step invoice run (Mail → Excel → NetSuite), 600s apart.
    private func invoiceRunSpans(now: Date) -> [ActivitySpan] {
        (0..<4).flatMap { i -> [ActivitySpan] in
            let base = now.addingTimeInterval(Double(i) * 600)
            return [
                ActivitySpan(bundleID: "com.apple.mail", appName: "Mail", windowTitle: "Invoice #\(i)", start: base, end: base.addingTimeInterval(30)),
                ActivitySpan(bundleID: "com.microsoft.Excel", appName: "Microsoft Excel", windowTitle: "Purchase Orders.xlsx", start: base.addingTimeInterval(35), end: base.addingTimeInterval(75), shortcuts: "⌘C×1"),
                ActivitySpan(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Vendor Bills — NetSuite", start: base.addingTimeInterval(80), end: base.addingTimeInterval(125), shortcuts: "⌘V×1"),
            ]
        }
    }

    /// When no capture landed inside ANY occurrence, the walkthrough stays empty
    /// (honest) rather than back-filling unrelated content from the gaps and
    /// labelling it "one real run".
    func testNoMomentsWhenCapturesFallOutsideOccurrences() {
        let store = Store.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.insertBatch(invoiceRunSpans(now: now))
        // The only narrative matches a step unit (NetSuite) but sits in a gap.
        store.insertNarrative(SceneNarrative(timestamp: now.addingTimeInterval(300), appName: "Google Chrome", windowTitle: "Vendor Bills — NetSuite", text: "A NetSuite page open outside any run."))

        let pattern = PatternMiner.mine(spans: store.spans(from: .distantPast, to: .distantFuture, demo: false)).first { $0.apps.contains("NetSuite") && $0.apps.contains("Excel") }
        XCTAssertNotNil(pattern)
        let insight = WorkflowInsighter.build(pattern!, store: store, demo: false)
        XCTAssertTrue(insight.moments.isEmpty, "gap content was back-filled as a fake 'real run'")
    }

    // MARK: - Automatability judgement

    /// Junk UI text is NOT treated as a field the user fills.
    func testJunkFieldLabelsRejected() {
        XCTAssertNil(WorkflowInsighter.cleanFieldName("Press tab then enter to ask AI Mode"))
        XCTAssertNil(WorkflowInsighter.cleanFieldName("Chat with ChatGPT"))
        XCTAssertNil(WorkflowInsighter.cleanFieldName("Ask AI Mode"))
        XCTAssertNil(WorkflowInsighter.cleanFieldName("Search Google or type a URL"))
        // Real short field names survive (class tags and (optional)/(required) stripped).
        XCTAssertEqual(WorkflowInsighter.cleanFieldName("Amount [currency]"), "Amount")
        XCTAssertEqual(WorkflowInsighter.cleanFieldName("Last name (optional)"), "Last name")
        XCTAssertEqual(WorkflowInsighter.cleanFieldName("Invoice Number [identifier]"), "Invoice Number")
    }

    /// A field seen in only one of many runs is not "filled each time".
    func testFieldConsistencyThreshold() {
        func span(_ fields: String) -> ActivitySpan {
            ActivitySpan(bundleID: "b", appName: "Chrome", windowTitle: "x", start: Date(), end: Date().addingTimeInterval(10), fields: fields)
        }
        // 4 occurrences; "First name" only in one; "Invoice Number" in three.
        let occs = [[span("First name")], [span("Invoice Number")], [span("Invoice Number")], [span("Invoice Number")]]
        let consistent = WorkflowInsighter.consistentFieldNames(occs)
        XCTAssertTrue(consistent.contains("Invoice Number"))
        XCTAssertFalse(consistent.contains("First name"))
    }

    /// Reading/analysis narratives with no data movement → NOT automatable, and
    /// the copy names it as thinking work rather than inventing a $ figure.
    func testCognitiveWorkNotAutomatable() {
        let narrs = [
            SceneNarrative(timestamp: Date(), appName: "Chrome", windowTitle: "Hotel Strategy", text: "The user is reviewing and analyzing a discussion about hotel profitability."),
            SceneNarrative(timestamp: Date(), appName: "Claude", windowTitle: "Claude", text: "The person is evaluating strategies and reading through the analysis."),
        ]
        let (text, automatable) = WorkflowInsighter.analyzeAutomation(
            pattern: makePattern(apps: ["Google Chrome", "Claude"], score: 52),
            occSpans: [[ActivitySpan(bundleID: "b", appName: "Google Chrome", windowTitle: "Hotel Strategy", start: Date(), end: Date().addingTimeInterval(10))]],
            narratives: narrs
        )
        XCTAssertFalse(automatable)
        XCTAssertFalse(text.contains("$"))
        XCTAssertTrue(text.lowercased().contains("reading") || text.lowercased().contains("person"))
    }

    private func makePattern(apps: [String], score: Int) -> WorkflowPattern {
        WorkflowPattern(apps: apps, occurrences: 8, medianDuration: 600, totalDuration: 4800,
                        daysObserved: 2, automationScore: score, sampleTitles: [], windows: [], stepLabels: apps)
    }
}
