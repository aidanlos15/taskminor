import XCTest
@testable import Availeth

/// The story layer's contract: the model is shown a labelled record in plain
/// words, is only asked when there is something to write, and is believed only
/// when everything it says is in the record.
final class StoryWriterTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func span(_ app: String, _ title: String, keys: Int = 30, clicks: Int = 5, shortcuts: String = "", fields: String = "") -> ActivitySpan {
        ActivitySpan(bundleID: "id.\(app)", appName: app, windowTitle: title, start: base, end: base.addingTimeInterval(30),
                     keystrokes: keys, clicks: clicks, shortcuts: shortcuts, fields: fields)
    }

    private func transfer(from: String, _ fromTitle: String, to: String, _ toTitle: String, field: String = "") -> Transfer {
        Transfer(at: base.addingTimeInterval(20), fromBundleID: "id.\(from)", fromApp: from, fromUnit: from, fromTitle: fromTitle,
                 toBundleID: "id.\(to)", toApp: to, toUnit: to, toTitle: toTitle, toField: field, gapSeconds: 12)
    }

    // MARK: Record

    func testSymbolsBecomeWordsAndCountsAreDropped() {
        XCTAssertEqual(StoryWriter.keyWordList(["⌫×5, ↵×4, ⌘C×2, ⌘V×2"]), ["Delete", "Enter", "copy", "paste"])
        XCTAssertEqual(StoryWriter.keyWord("⌘K"), "Cmd+K")
    }

    func testRecordLabelsWindowsAndAttributesFieldsToTheirWindow() {
        let r = StoryWriter.minuteRecord(spans: [
            span("Microsoft Excel", "Purchase Orders.xlsx", shortcuts: "⌘C×1"),
            span("Google Chrome", "Vendor Bills - NetSuite", shortcuts: "⌘V×1", fields: "Invoice Number [identifier], Search or enter website name [name]"),
        ], transfers: [transfer(from: "Microsoft Excel", "Purchase Orders.xlsx", to: "Google Chrome", "Vendor Bills - NetSuite", field: "Invoice Number")], narratives: [])
        XCTAssertTrue(r.text.contains("Google Chrome \"Vendor Bills - NetSuite\" (typed into fields: Invoice Number)"), r.text)
        XCTAssertFalse(r.text.contains("website name"), "browser chrome is not a field")
        XCTAssertFalse(r.text.contains("[identifier]"), "value-kind tags are stripped")
        XCTAssertTrue(r.text.contains("Data moved: Microsoft Excel \"Purchase Orders.xlsx\" to Google Chrome \"Vendor Bills - NetSuite\", into field Invoice Number"), r.text)
        XCTAssertFalse(r.isThin)
    }

    func testWindowsAndTypingOnlyIsThin() {
        let r = StoryWriter.minuteRecord(spans: [span("Code", "main.swift — taskminor", keys: 186, clicks: 16, shortcuts: "⌘C×2, ⌘V×2")], transfers: [], narratives: [])
        XCTAssertTrue(r.isThin)
        XCTAssertEqual(StoryWriter.plainEntry(r), "Typed at length in Code (main.swift — taskminor), copying and pasting.")
    }

    func testPlainEntryCarriesFieldsAndMoves() {
        let r = StoryWriter.minuteRecord(spans: [
            span("Microsoft Excel", "PO.xlsx", keys: 5),
            span("Google Chrome", "Vendor Bills", keys: 40, fields: "Amount [currency]"),
        ], transfers: [transfer(from: "Microsoft Excel", "PO.xlsx", to: "Google Chrome", "Vendor Bills", field: "Amount")], narratives: [])
        let line = StoryWriter.plainEntry(r)
        XCTAssertTrue(line.hasPrefix("Worked in Microsoft Excel (PO.xlsx) and Google Chrome (Vendor Bills)."), line)
        XCTAssertTrue(line.contains("Typed into Amount in Google Chrome."), line)
        XCTAssertTrue(line.contains("Moved data from Microsoft Excel \"PO.xlsx\" to Google Chrome \"Vendor Bills\", into field Amount."), line)
    }

    func testPromptsNeverAskForAnEmployeeOrAutomationJudgement() {
        let r = StoryWriter.minuteRecord(spans: [span("Mail", "Inbox", fields: "To")], transfers: [], narratives: [])
        let p = StoryWriter.minutePrompt(r)
        XCTAssertFalse(p.lowercased().contains("employee's"))
        XCTAssertFalse(p.lowercased().contains("automat"))
        XCTAssertTrue(p.contains("Start with a verb"))
        let t = StoryWriter.taskPrompt(StoryWriter.taskRecord(minutes: [], transfers: []))
        XCTAssertFalse(t.lowercased().contains("decide how to automate"))
    }

    // MARK: Checks on the model's entry

    private var invoiceRecord: StoryWriter.MinuteRecord {
        StoryWriter.minuteRecord(spans: [
            span("Microsoft Excel", "Purchase Orders.xlsx"),
            span("Google Chrome", "Vendor Bills - NetSuite", fields: "Invoice Number, Amount"),
        ], transfers: [transfer(from: "Microsoft Excel", "Purchase Orders.xlsx", to: "Google Chrome", "Vendor Bills - NetSuite", field: "Invoice Number")], narratives: [])
    }

    func testGroundedEntryIsAccepted() {
        let out = "Copied a purchase order reference from Purchase Orders.xlsx into the Invoice Number field in NetSuite, then typed the Amount."
        XCTAssertEqual(StoryWriter.acceptEntry(out, record: invoiceRecord), out)
    }

    func testEntryNamingAnAppNotInTheRecordIsRejected() {
        XCTAssertNil(StoryWriter.acceptEntry("Pasted the reference into QuickBooks and typed the Amount.", record: invoiceRecord))
    }

    func testEntryWithInventedNumberIsRejected() {
        XCTAssertNil(StoryWriter.acceptEntry("Entered 14 vendor bills in NetSuite from Purchase Orders.xlsx.", record: invoiceRecord))
    }

    func testEntryThatNamesThePersonIsRejected() {
        XCTAssertNil(StoryWriter.acceptEntry("Typed the Amount in NetSuite. The employee then checked Purchase Orders.xlsx.", record: invoiceRecord))
    }

    func testEntryClaimingAMoveWithoutATransferIsRejected() {
        let noMove = StoryWriter.minuteRecord(spans: [span("Microsoft Excel", "PO.xlsx", shortcuts: "⌘C×1"), span("Mail", "Inbox", fields: "To")], transfers: [], narratives: [])
        XCTAssertNil(StoryWriter.acceptEntry("Copied a total from PO.xlsx into an email in Mail.", record: noMove))
        // A paste inside one window is a fair thing to say.
        XCTAssertNotNil(StoryWriter.acceptEntry("Pasted an address into the To field of an email in Mail.", record: noMove))
    }

    func testEntryCompletingACutTitleIsRejected() {
        let cut = StoryWriter.minuteRecord(spans: [span("Code", "Stampede.ai graphics ren…", fields: "Search")], transfers: [], narratives: [])
        _ = cut
        let r = StoryWriter.minuteRecord(spans: [span("Code", "Stampede.ai graphics ren…", fields: "Name")], transfers: [], narratives: [])
        XCTAssertNil(StoryWriter.acceptEntry("Edited the Stampede.ai graphics rename file in Code and typed a Name.", record: r))
        XCTAssertNotNil(StoryWriter.acceptEntry("Edited Stampede.ai graphics ren… in Code and typed a Name.", record: r))
    }

    func testChatOpenersAreStrippedAndLengthCapped() {
        let out = StoryWriter.Check.tidy("This minute, the user typed the Amount in NetSuite. Then checked Purchase Orders.xlsx. Then saved. Then more. And more.", maxSentences: 3)
        XCTAssertTrue(out.hasPrefix("The user typed") == false, out)
        XCTAssertEqual(StoryWriter.Check.sentences(out).count, 3)
    }

    // MARK: Task record, title and story

    private func minute(_ i: Int, apps: String, text: String, keys: Int = 40, shortcuts: String = "", fields: String = "") -> MinuteSummary {
        MinuteSummary(minuteStart: base.addingTimeInterval(Double(i) * 60), text: text, apps: apps, keystrokes: keys, clicks: 4,
                      shortcuts: shortcuts, fields: fields, sourceCount: 0)
    }

    func testTaskRecordRanksWindowsAndCollapsesRepeatedEntries() {
        let mins = (0..<10).map { i in
            minute(i, apps: i < 8 ? "Google Chrome — Vendor Bills - NetSuite, Microsoft Excel — PO.xlsx" : "Mail — Inbox",
                   text: i < 8 ? "Copied a reference into NetSuite." : "Wrote an email in Mail.", shortcuts: "⌘C×1, ⌘V×1", fields: i < 8 ? "Invoice Number" : "")
        }
        let r = StoryWriter.taskRecord(minutes: mins, transfers: [transfer(from: "Microsoft Excel", "PO.xlsx", to: "Google Chrome", "Vendor Bills - NetSuite", field: "Invoice Number")])
        XCTAssertTrue(r.text.contains("Google Chrome \"Vendor Bills - NetSuite\" (most of the time)"), r.text)
        XCTAssertTrue(r.text.contains("Mail \"Inbox\" (briefly)"), r.text)
        XCTAssertTrue(r.text.contains("- Copied a reference into NetSuite. (repeated many times)"), r.text)
        XCTAssertTrue(r.text.contains("Length: about a quarter of an hour"), r.text)
        XCTAssertEqual(r.topWindow?.app, "Google Chrome")
    }

    func testTitleWithBannedWordOrForeignNameFallsBack() {
        let mins = [minute(0, apps: "Code — main.swift", text: "Edited main.swift in Code."), minute(1, apps: "Code — main.swift", text: "Edited main.swift in Code.")]
        let r = StoryWriter.taskRecord(minutes: mins, transfers: [])
        var (title, _) = StoryWriter.acceptTitleAndStory("STORY: Edited main.swift in Code.\nTITLE: Code Editing Automation", record: r)
        XCTAssertEqual(title, "Code · main.swift")
        (title, _) = StoryWriter.acceptTitleAndStory("STORY: Edited main.swift in Code.\nTITLE: Vanessa Baez daily edits", record: r)
        XCTAssertEqual(title, "Code · main.swift")
        (title, _) = StoryWriter.acceptTitleAndStory("STORY: Edited main.swift in Code.\nTITLE: Swift file edits", record: r)
        XCTAssertEqual(title, "Swift file edits")
    }

    func testStoryWithInventedAppFallsBackToPlainStory() {
        let mins = [minute(0, apps: "Code — main.swift", text: "Edited main.swift in Code."), minute(1, apps: "Safari — New chat - Claude", text: "Typed in a Claude chat in Safari.")]
        let r = StoryWriter.taskRecord(minutes: mins, transfers: [])
        let (_, story) = StoryWriter.acceptTitleAndStory("STORY: Edited main.swift in Code and checked figures in Microsoft Excel.\nTITLE: Swift edits", record: r)
        XCTAssertEqual(story, StoryWriter.plainStory(r))
        XCTAssertTrue(story.hasPrefix("A few minutes, mostly in Code \"main.swift\", also Safari \"New chat - Claude\"."), story)
    }

    func testNoModelStillYieldsTitleAndStory() {
        let mins = [minute(0, apps: "Microsoft Excel — PO.xlsx, Google Chrome — Vendor Bills", text: "x", fields: "Amount")]
        let r = StoryWriter.taskRecord(minutes: mins, transfers: [])
        let (title, story) = StoryWriter.acceptTitleAndStory(nil, record: r)
        XCTAssertEqual(title, "Microsoft Excel and Google Chrome")
        XCTAssertTrue(story.contains("Typed into Amount."), story)
    }

    func testDemoStoriesUseTheSameRegister() {
        let store = Store.inMemory()
        DemoData.seedSummaries(into: store)
        for t in store.taskSummaries(from: .distantPast, to: .distantFuture, demo: true) {
            XCTAssertFalse(t.text.lowercased().contains("employee"), t.text)
            XCTAssertFalse(t.text.lowercased().contains("candidate"), t.text)
        }
    }
}
