import XCTest
@testable import Availeth

final class DetailedTaskTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private var nextID: Int64 = 1

    private func span(app: String, title: String, atMin: Double, durMin: Double = 3) -> ActivitySpan {
        let s = base.addingTimeInterval(atMin * 60)
        defer { nextID += 1 }
        return ActivitySpan(id: nextID, bundleID: "com.x", appName: app, windowTitle: title, start: s, end: s.addingTimeInterval(durMin * 60))
    }
    private func narr(app: String, title: String, atMin: Double, text: String) -> SceneNarrative {
        SceneNarrative(timestamp: base.addingTimeInterval(atMin * 60), appName: app, windowTitle: title, text: text)
    }
    private func label(_ span: ActivitySpan, _ canon: String, source: LabelSource = .model) -> SpanLabel {
        let unit = WorkflowUnit.label(app: span.appName, title: span.windowTitle)
        return SpanLabel(spanID: span.id, sessionKey: "\(unit)\u{1F}\(span.id)", unit: unit,
                         titleKey: LabelKey.canonKey(LabelKey.cleanTitle(span.windowTitle, appName: span.appName)),
                         intent: canon, canon: canon, source: source, created: base)
    }

    /// Detailed content narratives are attached to their task and shown.
    func testNarrativesAttachedToTask() {
        let spans = [span(app: "Microsoft Excel", title: "Purchase Orders.xlsx", atMin: 0)]
        let narrs = [narr(app: "Microsoft Excel", title: "Purchase Orders.xlsx", atMin: 1, text: "Searching the sheet for a PO number.")]
        let tasks = Analytics.detailedTasks(spans, narratives: narrs)
        let excel = tasks.first { $0.title.contains("Purchase Orders") }
        XCTAssertNotNil(excel)
        XCTAssertEqual(excel?.moments.count, 1)
        XCTAssertTrue(excel?.preview.contains("PO number") ?? false)
        XCTAssertEqual(excel?.source, .title)
    }

    /// Without labels a bare "Claude" lump is ONE honest row — never titled from
    /// a screenshot sentence — and its sittings are counted by gap, not by refocus.
    func testUnlabelledGenericLumpCollapsesOntoTheUnit() {
        let spans = [
            span(app: "Claude", title: "Claude", atMin: 0), span(app: "Claude", title: "Claude", atMin: 3),
            span(app: "Claude", title: "Claude", atMin: 20), span(app: "Claude", title: "Claude", atMin: 23),
        ]
        let narrs = [
            narr(app: "Claude", title: "Claude", atMin: 1, text: "The user is asking Claude how to structure a hotel profitability model."),
            narr(app: "Claude", title: "Claude", atMin: 21, text: "The user is asking Claude to debug a Swift build error about a missing type."),
        ]
        let tasks = Analytics.detailedTasks(spans, narratives: narrs)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].title, "Claude")
        XCTAssertEqual(tasks[0].source, .fallback)
        XCTAssertEqual(tasks[0].sessions, 2, "two sittings separated by a 14-minute gap")
        XCTAssertEqual(tasks[0].moments.count, 2)
    }

    /// With labels, sittings batch by intent: two named tasks, each with its own
    /// moments and duration, and a third sitting adopting the first's title.
    func testLabelsBatchSittingsIntoIntentTasks() {
        let a1 = span(app: "Claude", title: "Claude", atMin: 0), a2 = span(app: "Claude", title: "Claude", atMin: 3)
        let b1 = span(app: "Claude", title: "Claude", atMin: 20), b2 = span(app: "Claude", title: "Claude", atMin: 23)
        let a3 = span(app: "Google Chrome", title: "Claude - Google Chrome - Aidan", atMin: 60)
        let labels: [Int64: SpanLabel] = Dictionary(uniqueKeysWithValues: [
            label(a1, "Structure a hotel profitability model"), label(a2, "Structure a hotel profitability model"),
            label(b1, "Debug a Swift build error"), label(b2, "Debug a Swift build error"),
            label(a3, "Structure a hotel profitability model"),
        ].map { ($0.spanID, $0) })
        let narrs = [
            narr(app: "Claude", title: "Claude", atMin: 1, text: "The user is asking Claude how to structure a hotel profitability model."),
            narr(app: "Claude", title: "Claude", atMin: 21, text: "The user is asking Claude to debug a Swift build error about a missing type."),
            narr(app: "Google Chrome", title: "Claude - Google Chrome - Aidan", atMin: 61, text: "Refining the model's revenue assumptions."),
        ]
        let tasks = Analytics.detailedTasks([a1, a2, b1, b2, a3], narratives: narrs, labels: labels)
        XCTAssertEqual(tasks.map(\.title), ["Structure a hotel profitability model", "Debug a Swift build error"], "longest first")
        let hotel = tasks[0]
        XCTAssertEqual(hotel.appUnit, "Claude")
        XCTAssertEqual(hotel.sessions, 2)
        XCTAssertEqual(hotel.duration, 9 * 60)
        XCTAssertEqual(hotel.moments.count, 2, "moments attach by unit and sitting window, across app and browser")
        XCTAssertEqual(hotel.source, .model)
        XCTAssertEqual(hotel.runs.count, 2)
        XCTAssertEqual(hotel.variants, ["Claude"])
        let swift = tasks[1]
        XCTAssertEqual(swift.moments.map(\.text), ["The user is asking Claude to debug a Swift build error about a missing type."])
    }

    /// A good window title is never touched, with or without labels around it.
    func testInformativeTitlesPassThroughUnchanged() {
        let ads = span(app: "Google Chrome", title: "Smart campaign - Ring of Kerry Hotel - Google Ads - Google Chrome - Ring", atMin: 0)
        let other = span(app: "Claude", title: "Claude", atMin: 10)
        let labels = [other.id: label(other, "Debug a Swift build error")]
        let tasks = Analytics.detailedTasks([ads, other], narratives: [], labels: labels)
        let row = tasks.first { $0.appUnit == "Google Ads" }
        XCTAssertEqual(row?.title, "Smart campaign - Ring of Kerry Hotel - Google Ads", "browser + profile tail is stripped, nothing else")
        XCTAssertEqual(row?.source, .title)
        XCTAssertEqual(Analytics.detailedTasks([ads], narratives: []).first?.title, row?.title)
    }

    /// A browser tab's task is labeled by its SITE unit, not "Chrome".
    func testBrowserTaskUsesSiteUnit() {
        let spans = [span(app: "Google Chrome", title: "Vendor Bills - NetSuite - Google Chrome - Aidan", atMin: 0)]
        let tasks = Analytics.detailedTasks(spans, narratives: [])
        XCTAssertEqual(tasks.first?.appUnit, "NetSuite")
    }

    func testOrderingIsDeterministicOnTies() {
        let spans = [span(app: "Claude", title: "Claude", atMin: 0), span(app: "Notes", title: "Notes", atMin: 10), span(app: "Slack", title: "Slack", atMin: 20)]
        let first = Analytics.detailedTasks(spans, narratives: []).map(\.id)
        for _ in 0..<20 { XCTAssertEqual(Analytics.detailedTasks(spans, narratives: []).map(\.id), first) }
    }
}
