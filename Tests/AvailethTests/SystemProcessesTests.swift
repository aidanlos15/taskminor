import AppKit
import XCTest
@testable import Availeth

final class SystemProcessesTests: XCTestCase {

    func testKnownAgentsAndApplePolicyRule() {
        XCTAssertTrue(SystemProcesses.isSystem(bundleID: "com.apple.loginwindow", activationPolicy: .accessory))
        XCTAssertTrue(SystemProcesses.isSystem(bundleID: "com.apple.CaptiveNetworkAssistant", activationPolicy: nil))
        XCTAssertTrue(SystemProcesses.isSystem(bundleID: "com.apple.SecurityAgent", activationPolicy: .regular), "explicit list wins regardless of policy")
        XCTAssertTrue(SystemProcesses.isSystem(bundleID: "com.apple.someNewHelper", activationPolicy: .accessory), "an Apple non-Dock process is a system piece")
        XCTAssertTrue(SystemProcesses.isSystem(bundleID: "com.apple.someNewHelper", activationPolicy: .prohibited))
        XCTAssertFalse(SystemProcesses.isSystem(bundleID: "com.apple.Notes", activationPolicy: .regular))
        XCTAssertFalse(SystemProcesses.isSystem(bundleID: "com.apple.finder", activationPolicy: .regular))
        XCTAssertFalse(SystemProcesses.isSystem(bundleID: "com.apple.systempreferences", activationPolicy: .regular))
        XCTAssertFalse(SystemProcesses.isSystem(bundleID: "com.electron.wispr-flow", activationPolicy: .accessory), "third-party menu-bar apps are real work")
        XCTAssertFalse(SystemProcesses.isSystem(bundleID: "com.google.Chrome", activationPolicy: .regular))
    }

    func testCleanAppNameStripsFormatMarks() {
        XCTAssertEqual(SystemProcesses.cleanAppName("\u{200E}WhatsApp"), "WhatsApp")
        XCTAssertEqual(SystemProcesses.cleanAppName(" Google Chrome "), "Google Chrome")
        XCTAssertEqual(SystemProcesses.cleanAppName("Claude"), "Claude")
    }

    func testPurgeRemovesOnlySystemRowsAndTheirLabels() {
        let store = Store.inMemory()
        let now = Date()
        let lock = ActivitySpan(bundleID: "com.apple.loginwindow", appName: "loginwindow", windowTitle: "", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(-500))
        let chrome = ActivitySpan(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Docs", start: now.addingTimeInterval(-400), end: now.addingTimeInterval(-300))
        let demoLock = ActivitySpan(bundleID: "com.apple.loginwindow", appName: "loginwindow", windowTitle: "", start: now.addingTimeInterval(-200), end: now.addingTimeInterval(-100), isDemo: true)
        let lockID = store.insert(lock), chromeID = store.insert(chrome)
        store.insert(demoLock)
        store.insertSpanLabels([
            SpanLabel(spanID: lockID, sessionKey: "a", unit: "loginwindow", titleKey: "", intent: "loginwindow", canon: "loginwindow", source: .fallback, created: now),
            SpanLabel(spanID: chromeID, sessionKey: "b", unit: "Chrome", titleKey: "docs", intent: "Docs", canon: "Docs", source: .title, created: now),
        ])
        store.insertNarrative(SceneNarrative(timestamp: now.addingTimeInterval(-550), appName: "Captive Network Assistant", windowTitle: "", text: "A Wi-Fi sign-in page.", imagePath: "/tmp/cna.png"))
        store.insertNarrative(SceneNarrative(timestamp: now.addingTimeInterval(-350), appName: "Google Chrome", windowTitle: "Docs", text: "Editing a doc.", imagePath: "/tmp/doc.png"))

        XCTAssertEqual(store.deleteSpans(bundleIDs: SystemProcesses.bundleIDs), 1)
        let live = store.spans(from: .distantPast, to: .distantFuture, demo: false)
        XCTAssertEqual(live.map(\.appName), ["Google Chrome"])
        XCTAssertEqual(store.spans(from: .distantPast, to: .distantFuture, demo: true).count, 1, "demo rows untouched")
        XCTAssertEqual(store.spanLabels(from: .distantPast, to: .distantFuture, demo: false).count, 1, "the orphaned label went with its span")

        XCTAssertEqual(store.deleteNarratives(appNames: SystemProcesses.appNames), ["/tmp/cna.png"])
        XCTAssertEqual(store.narratives(from: .distantPast, to: .distantFuture, demo: false).map(\.appName), ["Google Chrome"])
    }

    func testNormaliseAppNamesFixesStoredMarks() {
        let store = Store.inMemory()
        let now = Date()
        store.insert(ActivitySpan(bundleID: "net.whatsapp.WhatsApp", appName: "\u{200E}WhatsApp", windowTitle: "Chats", start: now.addingTimeInterval(-100), end: now.addingTimeInterval(-50)))
        store.insert(ActivitySpan(bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp", windowTitle: "Chats", start: now.addingTimeInterval(-40), end: now.addingTimeInterval(-10)))
        store.normaliseAppNames()
        let names = Set(store.spans(from: .distantPast, to: .distantFuture, demo: false).map(\.appName))
        XCTAssertEqual(names, ["WhatsApp"])
    }
}
