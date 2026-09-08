import XCTest
@testable import Availeth

final class DetailedTaskTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func span(app: String, title: String, atMin: Double, durMin: Double = 3) -> ActivitySpan {
        let s = base.addingTimeInterval(atMin * 60)
        return ActivitySpan(bundleID: "com.x", appName: app, windowTitle: title, start: s, end: s.addingTimeInterval(durMin * 60))
    }
    private func narr(app: String, title: String, atMin: Double, text: String) -> SceneNarrative {
        SceneNarrative(timestamp: base.addingTimeInterval(atMin * 60), appName: app, windowTitle: title, text: text)
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
    }

    /// A bare "Claude" lump splits into distinct conversations by time gap, each
    /// titled from its own content — not one 3h lump.
    func testGenericAppSplitsIntoConversations() {
        // Conversation A around minute 0–6, then a >5min gap, conversation B at 20–26.
        let spans = [
            span(app: "Claude", title: "Claude", atMin: 0), span(app: "Claude", title: "Claude", atMin: 3),
            span(app: "Claude", title: "Claude", atMin: 20), span(app: "Claude", title: "Claude", atMin: 23),
        ]
        let narrs = [
            narr(app: "Claude", title: "Claude", atMin: 1, text: "The user is asking Claude how to structure a hotel profitability model."),
            narr(app: "Claude", title: "Claude", atMin: 21, text: "The user is asking Claude to debug a Swift build error about a missing type."),
        ]
        let tasks = Analytics.detailedTasks(spans, narratives: narrs)
        let claudeTasks = tasks.filter { $0.appUnit == "Claude" }
        XCTAssertEqual(claudeTasks.count, 2, "Claude should split into 2 conversations, got \(claudeTasks.map(\.title))")
        XCTAssertTrue(claudeTasks.contains { $0.title.lowercased().contains("hotel profitability") })
        XCTAssertTrue(claudeTasks.contains { $0.title.lowercased().contains("swift build error") })
    }

    /// A browser tab's task is labeled by its SITE unit, not "Chrome".
    func testBrowserTaskUsesSiteUnit() {
        let spans = [span(app: "Google Chrome", title: "Vendor Bills - NetSuite - Google Chrome - Aidan", atMin: 0)]
        let tasks = Analytics.detailedTasks(spans, narratives: [])
        XCTAssertEqual(tasks.first?.appUnit, "NetSuite")
    }
}
