import XCTest
@testable import Availeth

final class EnrichmentStoreTests: XCTestCase {

    private func tempStore() -> Store {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("availeth-enrich-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Store(url: url)
    }

    func testInputCountsAndDocPathRoundtrip() {
        let store = tempStore()
        let now = Date()
        let span = ActivitySpan(
            bundleID: "com.microsoft.Excel", appName: "Microsoft Excel", windowTitle: "PO.xlsx",
            start: now.addingTimeInterval(-120), end: now.addingTimeInterval(-10),
            keystrokes: 148, clicks: 12, documentPath: "/Users/x/PO.xlsx"
        )
        store.insert(span)
        let fetched = store.spans(from: now.addingTimeInterval(-600), to: now, demo: false)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].keystrokes, 148)
        XCTAssertEqual(fetched[0].clicks, 12)
        XCTAssertEqual(fetched[0].documentPath, "/Users/x/PO.xlsx")
        XCTAssertGreaterThan(fetched[0].inputIntensity, 0)
    }

    func testScreenshotStoreRetentionPrune() {
        let store = tempStore()
        let now = Date()
        let old = Screenshot(timestamp: now.addingTimeInterval(-48 * 3600), appName: "A", windowTitle: "", path: "/tmp/old.png")
        let fresh = Screenshot(timestamp: now, appName: "B", windowTitle: "", path: "/tmp/fresh.png")
        store.insertScreenshot(old)
        store.insertScreenshot(fresh)
        XCTAssertEqual(store.screenshotCount(demo: false), 2)

        let pruned = store.pruneScreenshots(olderThan: now.addingTimeInterval(-24 * 3600))
        XCTAssertEqual(pruned, ["/tmp/old.png"])
        XCTAssertEqual(store.screenshotCount(demo: false), 1)

        let deleted = store.deleteScreenshots(scope: .live)
        XCTAssertEqual(deleted, ["/tmp/fresh.png"])
        XCTAssertEqual(store.screenshotCount(demo: false), 0)
    }

    /// Input monitor starts empty and drains cleanly.
    func testInputMonitorDrainsEmpty() {
        let monitor = InputMonitor()
        XCTAssertEqual(monitor.keystrokes, 0)
        let drained = monitor.drain()
        XCTAssertEqual(drained.keystrokes, 0)
        XCTAssertEqual(drained.clicks, 0)
        XCTAssertEqual(drained.shortcuts, "")
        XCTAssertEqual(drained.fields, "")
        XCTAssertFalse(monitor.isRunning)
    }

    func testShortcutsAndFieldsRoundtrip() {
        let store = tempStore()
        let now = Date()
        let span = ActivitySpan(
            bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Vendor Bills — NetSuite",
            start: now.addingTimeInterval(-200), end: now.addingTimeInterval(-10),
            keystrokes: 22, clicks: 5,
            shortcuts: "⌘C×4, ⌘V×4, Tab×12, ↵×3",
            fields: "Invoice Number [identifier], Amount [currency]"
        )
        store.insert(span)
        let fetched = store.spans(from: now.addingTimeInterval(-600), to: now, demo: false)
        XCTAssertEqual(fetched.first?.shortcuts, "⌘C×4, ⌘V×4, Tab×12, ↵×3")
        XCTAssertEqual(fetched.first?.fields, "Invoice Number [identifier], Amount [currency]")
    }

    /// Field classification derives from the label, never from content.
    func testFieldClassifierFromLabel() {
        XCTAssertEqual(FieldClassifier.classify("Amount"), "currency")
        XCTAssertEqual(FieldClassifier.classify("Total Due"), "currency")
        XCTAssertEqual(FieldClassifier.classify("Email Address"), "email")
        XCTAssertEqual(FieldClassifier.classify("Invoice Number"), "identifier")
        XCTAssertEqual(FieldClassifier.classify("Customer Name"), "name")
        XCTAssertEqual(FieldClassifier.classify("Search"), "search")
        XCTAssertNil(FieldClassifier.classify("Notes"))
    }

    /// Word-boundary matching: short tokens must not fire on substrings.
    func testFieldClassifierAvoidsSubstringFalsePositives() {
        XCTAssertNil(FieldClassifier.classify("Hidden"))   // contains "id" but not the word
        XCTAssertNil(FieldClassifier.classify("Notes"))    // contains "no" but not the word
        XCTAssertNil(FieldClassifier.classify("Description"))
        XCTAssertEqual(FieldClassifier.classify("PO"), "identifier") // whole word
    }

    /// The monitor drops every event while not counting (paused/excluded/secure).
    func testMonitorGatedByContext() {
        let monitor = InputMonitor()
        monitor.mode = .standard
        // Not counting → attribution and counts stay zero even if a field is set.
        monitor.setCounting(false)
        monitor.setField(label: "Amount", secure: false, className: "currency")
        let a = monitor.drain()
        XCTAssertEqual(a.keystrokes, 0)
        XCTAssertEqual(a.fields, "")

        // Counting but secure → still nothing (password field).
        monitor.setCounting(true)
        monitor.setField(label: "Password", secure: true, className: nil)
        XCTAssertTrue(monitor.secure)
        let b = monitor.drain()
        XCTAssertEqual(b.keystrokes, 0)
    }

    func testNarrativeStoreRoundtripAndDelete() {
        let store = tempStore()
        let now = Date()
        store.insertNarrative(SceneNarrative(timestamp: now, appName: "Google Chrome", windowTitle: "Vendor Bills — NetSuite", text: "Submitting a vendor bill for approval.", imagePath: "/tmp/scene-a.png", isDemo: false))
        store.insertNarrative(SceneNarrative(timestamp: now.addingTimeInterval(-60), appName: "Excel", windowTitle: "PO.xlsx", text: "Searching a spreadsheet.", isDemo: true))

        let live = store.narratives(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(60), demo: false)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.text, "Submitting a vendor bill for approval.")
        XCTAssertEqual(live.first?.imagePath, "/tmp/scene-a.png")
        XCTAssertEqual(store.narrativeCount(demo: false), 1)
        XCTAssertEqual(store.narrativeCount(demo: true), 1)

        let deletedPaths = store.deleteNarratives(scope: .live)
        XCTAssertEqual(deletedPaths, ["/tmp/scene-a.png"]) // image path returned for file cleanup
        XCTAssertEqual(store.narrativeCount(demo: false), 0)
        XCTAssertEqual(store.narrativeCount(demo: true), 1) // demo untouched
    }

    func testNarrativeRetentionPruneReturnsImagePaths() {
        let store = tempStore()
        let now = Date()
        store.insertNarrative(SceneNarrative(timestamp: now.addingTimeInterval(-48*3600), appName: "A", windowTitle: "", text: "old", imagePath: "/tmp/old-scene.png", isDemo: false))
        store.insertNarrative(SceneNarrative(timestamp: now, appName: "B", windowTitle: "", text: "fresh", imagePath: "/tmp/fresh-scene.png", isDemo: false))
        let pruned = store.pruneNarratives(olderThan: now.addingTimeInterval(-24*3600))
        XCTAssertEqual(pruned, ["/tmp/old-scene.png"])
        XCTAssertEqual(store.narrativeCount(demo: false), 1)
    }

    /// The local scrub removes the common PII shapes a model might leak.
    func testNarrativeSanitizerScrubsPII() {
        XCTAssertEqual(
            NarrativeSanitizer.scrub("Submit vendor bill for Acme Corp's invoice INV-10247 to approval."),
            "Submit vendor bill for Acme Corp's invoice [id] to approval."
        )
        XCTAssertEqual(NarrativeSanitizer.scrub("Entering amount $18,672.44 in the form."),
                       "Entering amount [amount] in the form.")
        XCTAssertEqual(NarrativeSanitizer.scrub("Emailing john@company.com about it."),
                       "Emailing [email] about it.")
        XCTAssertEqual(NarrativeSanitizer.scrub("Searching PO 4839201 in the sheet."),
                       "Searching PO [id] in the sheet.")
        // A clean narrative is left intact.
        XCTAssertEqual(NarrativeSanitizer.scrub("Submitting a vendor bill for approval in NetSuite."),
                       "Submitting a vendor bill for approval in NetSuite.")
    }

    /// The interpreter reports unavailable gracefully when nothing answers.
    /// Both roles must report separately: the story layer depends on the text
    /// answer, storyline capture on the vision one.
    func testInterpreterUnavailableOnBadHost() async {
        let interp = OllamaInterpreter(visionModel: "none", textModel: "none", host: "http://127.0.0.1:1")
        let available = await interp.isAvailable()
        XCTAssertFalse(available)
        let textAvailable = await interp.isTextAvailable()
        XCTAssertFalse(textAvailable)
        let narrated = await interp.narrate(pngData: Data([0x89, 0x50]), context: SceneContext(appName: "x", windowTitle: "y"))
        XCTAssertNil(narrated)
        let summarized = await interp.summarize(prompt: "hello", maxTokens: 10)
        XCTAssertNil(summarized)
    }

    func testIdleSessionStoreAndTotal() {
        let store = tempStore()
        let now = Date()
        store.insertIdleSession(IdleSession(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-3000), isDemo: false)) // 10 min
        store.insertIdleSession(IdleSession(start: now.addingTimeInterval(-1000), end: now.addingTimeInterval(-700), isDemo: true))   // demo
        let live = store.idleSessions(from: now.addingTimeInterval(-7200), to: now, demo: false)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(store.idleSeconds(from: now.addingTimeInterval(-7200), to: now, demo: false), 600, accuracy: 1)
        store.deleteIdleSessions(scope: .live)
        XCTAssertTrue(store.idleSessions(from: now.addingTimeInterval(-7200), to: now, demo: false).isEmpty)
        XCTAssertEqual(store.idleSessions(from: now.addingTimeInterval(-7200), to: now, demo: true).count, 1)
    }

    /// Re-inserting the same minute is a no-op (UNIQUE index), and latestMinuteStart
    /// gives a durable resume point — the crash-safety fix.
    func testMinuteSummaryIdempotentAndResume() {
        let store = tempStore()
        let m0 = Date(timeIntervalSince1970: 1_700_000_000)
        let m1 = m0.addingTimeInterval(60)
        store.insertMinuteSummary(MinuteSummary(minuteStart: m0, text: "a", apps: "Excel", keystrokes: 5, clicks: 1, shortcuts: "", fields: "", sourceCount: 1))
        store.insertMinuteSummary(MinuteSummary(minuteStart: m0, text: "duplicate", apps: "Excel", keystrokes: 5, clicks: 1, shortcuts: "", fields: "", sourceCount: 1)) // same minute → ignored
        store.insertMinuteSummary(MinuteSummary(minuteStart: m1, text: "b", apps: "Chrome", keystrokes: 2, clicks: 0, shortcuts: "", fields: "", sourceCount: 1))

        let all = store.minuteSummaries(from: m0.addingTimeInterval(-60), to: m1.addingTimeInterval(120), demo: false)
        XCTAssertEqual(all.count, 2) // the duplicate was ignored
        XCTAssertEqual(store.latestMinuteStart(demo: false), m1)
    }

    /// insertTaskAndLink links the minutes atomically.
    func testInsertTaskAndLink() {
        let store = tempStore()
        let m0 = Date(timeIntervalSince1970: 1_700_000_000)
        let id0 = store.insertMinuteSummary(MinuteSummary(minuteStart: m0, text: "a", apps: "Excel", keystrokes: 5, clicks: 1, shortcuts: "", fields: "", sourceCount: 1))
        let id1 = store.insertMinuteSummary(MinuteSummary(minuteStart: m0.addingTimeInterval(60), text: "b", apps: "Excel", keystrokes: 5, clicks: 1, shortcuts: "", fields: "", sourceCount: 1))
        XCTAssertEqual(store.ungroupedMinuteSummaries(demo: false).count, 2)
        let taskID = store.insertTaskAndLink(TaskSummary(start: m0, end: m0.addingTimeInterval(120), title: "T", text: "S", apps: "Excel", minuteCount: 2, automatable: "Low — x"), minuteIDs: [id0, id1])
        XCTAssertGreaterThan(taskID, 0)
        XCTAssertEqual(store.ungroupedMinuteSummaries(demo: false).count, 0) // both linked
        XCTAssertEqual(store.minutesForTask(taskID).count, 2)
    }

    /// setCounting(false) also clears the secure flag so stale state can't leak.
    func testSetCountingClearsSecure() {
        let monitor = InputMonitor()
        monitor.setCounting(true)
        monitor.setField(label: "x", secure: true, className: nil)
        XCTAssertTrue(monitor.secure)
        monitor.setCounting(false)
        XCTAssertFalse(monitor.secure)
    }
}
