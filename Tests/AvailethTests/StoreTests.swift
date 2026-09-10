import XCTest
@testable import Availeth

final class StoreTests: XCTestCase {

    private func tempStore() -> Store {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("availeth-test-\(UUID().uuidString).sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return Store(url: url)
    }

    func testInsertAndFetchRoundtrip() {
        let store = tempStore()
        let now = Date()
        let span = ActivitySpan(
            bundleID: "com.test.app", appName: "Test App", windowTitle: "Doc.txt",
            start: now.addingTimeInterval(-600), end: now.addingTimeInterval(-300)
        )
        let id = store.insert(span)
        XCTAssertGreaterThan(id, 0)

        let fetched = store.spans(from: now.addingTimeInterval(-3600), to: now, demo: false)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].appName, "Test App")
        XCTAssertEqual(fetched[0].windowTitle, "Doc.txt")
        XCTAssertEqual(fetched[0].start.timeIntervalSince1970, span.start.timeIntervalSince1970, accuracy: 0.01)
    }

    func testTransferPayloadRoundtripsAndIsCapped() {
        let store = tempStore()
        let now = Date()
        let long = String(repeating: "x", count: 5000)
        store.insert(transfer: Transfer(
            at: now.addingTimeInterval(-10),
            fromBundleID: "a", fromApp: "Excel", fromUnit: "Excel", fromTitle: "Book1",
            toBundleID: "b", toApp: "NetSuite", toUnit: "NetSuite", toTitle: "Invoice",
            toField: "Amount", gapSeconds: 3, payload: "ACME-1042"
        ))
        store.insert(transfer: Transfer(
            at: now.addingTimeInterval(-5),
            fromBundleID: "a", fromApp: "Excel", fromUnit: "Excel", fromTitle: "Book1",
            toBundleID: "b", toApp: "NetSuite", toUnit: "NetSuite", toTitle: "Invoice",
            toField: "Notes", gapSeconds: 2, payload: long
        ))
        let out = store.transfers(from: now.addingTimeInterval(-60), to: now, demo: false)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].payload, "ACME-1042")
        XCTAssertEqual(out[1].payload.count, 4000)
    }

    func testDemoAndLiveAreSeparated() {
        let store = tempStore()
        let now = Date()
        var live = ActivitySpan(bundleID: "a", appName: "Live", windowTitle: "", start: now.addingTimeInterval(-100), end: now)
        var demo = live
        demo.appName = "Demo"
        demo.isDemo = true
        store.insert(live)
        store.insert(demo)

        XCTAssertEqual(store.spans(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(10), demo: false).map(\.appName), ["Live"])
        XCTAssertEqual(store.spans(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(10), demo: true).map(\.appName), ["Demo"])
        XCTAssertEqual(store.spanCount(demo: false), 1)
        XCTAssertEqual(store.spanCount(demo: true), 1)

        live.appName = "Live" // silence unused-var warning
    }

    func testBatchInsertAndDelete() {
        let store = tempStore()
        let now = Date()
        let batch: [ActivitySpan] = (0..<50).map { (i: Int) in
            let endOffset: TimeInterval = TimeInterval(i) * -60
            let startOffset: TimeInterval = endOffset - 60
            return ActivitySpan(
                bundleID: "b", appName: "App", windowTitle: "\(i)",
                start: now.addingTimeInterval(startOffset), end: now.addingTimeInterval(endOffset),
                isDemo: true
            )
        }
        store.insertBatch(batch)
        XCTAssertEqual(store.spanCount(demo: true), 50)

        store.deleteAll(demoOnly: true)
        XCTAssertEqual(store.spanCount(demo: true), 0)
    }
}
