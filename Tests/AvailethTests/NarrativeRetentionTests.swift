import XCTest
@testable import Availeth

/// Storyline retention is two-tier: frames go after a day, the text stays.
final class NarrativeRetentionTests: XCTestCase {

    func testImagePruneKeepsTheText() {
        let store = Store.inMemory()
        let now = Date()
        store.insertNarrative(SceneNarrative(timestamp: now.addingTimeInterval(-3 * 86400), appName: "Google Chrome",
                                             windowTitle: "Smart campaign - Google Ads", text: "Editing the campaign's ad copy.", imagePath: "/tmp/old.png"))
        store.insertNarrative(SceneNarrative(timestamp: now.addingTimeInterval(-600), appName: "Claude", windowTitle: "Claude",
                                             text: "Asking about accruals.", imagePath: "/tmp/fresh.png"))
        store.insertNarrative(SceneNarrative(timestamp: now.addingTimeInterval(-3 * 86400), appName: "Demo", windowTitle: "",
                                             text: "demo row", imagePath: "/tmp/demo.png", isDemo: true))

        let dropped = store.pruneNarrativeImages(olderThan: now.addingTimeInterval(-86400))
        XCTAssertEqual(dropped, ["/tmp/old.png"], "only the old live frame is deleted")

        let live = store.narratives(from: .distantPast, to: .distantFuture, demo: false)
        XCTAssertEqual(live.count, 2, "the text of the old narrative survives")
        let old = live.first { $0.text.contains("ad copy") }
        XCTAssertEqual(old?.imagePath, "", "its image path is cleared")
        XCTAssertEqual(live.first { $0.appName == "Claude" }?.imagePath, "/tmp/fresh.png")
        XCTAssertEqual(store.narratives(from: .distantPast, to: .distantFuture, demo: true).first?.imagePath, "/tmp/demo.png", "demo rows untouched")

        // A second pass has nothing left to drop.
        XCTAssertEqual(store.pruneNarrativeImages(olderThan: now.addingTimeInterval(-86400)), [])

        // Text retention is a separate, much later cut-off.
        XCTAssertEqual(store.pruneNarratives(olderThan: now.addingTimeInterval(-90 * 86400)), [])
        XCTAssertEqual(store.narratives(from: .distantPast, to: .distantFuture, demo: false).count, 2)
        XCTAssertEqual(store.pruneNarratives(olderThan: now.addingTimeInterval(-86400)), [], "an already image-less row returns no path")
        XCTAssertEqual(store.narratives(from: .distantPast, to: .distantFuture, demo: false).count, 1)
    }

    /// Steps of a days-old workflow still get their captured detail once text is kept.
    func testWorkflowStepsReadOldNarratives() {
        let store = Store.inMemory()
        let base = Date().addingTimeInterval(-3 * 86400)
        let apps = ["Claude", "Google Ads"]
        var windows: [DateInterval] = []
        for i in 0..<3 {
            let t = base.addingTimeInterval(Double(i) * 3600)
            store.insert(ActivitySpan(bundleID: "com.anthropic.claudefordesktop", appName: "Claude", windowTitle: "Claude", start: t, end: t.addingTimeInterval(60)))
            store.insert(ActivitySpan(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Smart campaign - Google Ads - Google Chrome - Ring", start: t.addingTimeInterval(70), end: t.addingTimeInterval(130)))
            store.insertNarrative(SceneNarrative(timestamp: t.addingTimeInterval(30), appName: "Claude", windowTitle: "Claude", text: "Drafting ad headlines with Claude.", imagePath: ""))
            windows.append(DateInterval(start: t, end: t.addingTimeInterval(130)))
        }
        let pattern = WorkflowPattern(apps: apps, occurrences: 3, medianDuration: 130, totalDuration: 390, daysObserved: 1,
                                      automationScore: 40, sampleTitles: [], windows: windows, stepLabels: ["Claude", "Smart campaign - Google Ads"])
        let insight = WorkflowInsighter.build(pattern, store: store, demo: false)
        XCTAssertEqual(insight.steps.first?.content, "Drafting ad headlines with Claude.")
        XCTAssertFalse(insight.moments.isEmpty, "a representative run has its moments even without images")
    }
}
