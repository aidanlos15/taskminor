import XCTest
@testable import Availeth

/// The stored window list on a minute row used to be joined with a comma, so a
/// window title with a comma in it broke apart and its pieces were read back as
/// apps. The three strings here are real rows from the owner's store.
final class AppListTests: XCTestCase {

    // MARK: New format

    func testRoundTripKeepsTitlesWithCommasWhole() {
        let items = [
            "Safari — The New York Times - Breaking News, US News, World News and Videos",
            "Code — Stampede.ai graphics ren… — astra",
            "Finder",
        ]
        let stored = AppList.join(items)
        XCTAssertTrue(stored.contains(AppList.separator), "entries are joined with the unit separator")
        XCTAssertEqual(AppList.parse(stored), items)
        XCTAssertEqual(AppList.appNames(stored), ["Safari", "Code", "Finder"])
    }

    func testEmptyEntriesAreDropped() {
        XCTAssertEqual(AppList.parse(""), [])
        XCTAssertEqual(AppList.join(["", "Safari"]), "Safari")
    }

    // MARK: Old rows

    /// A comma inside a title no longer starts a new entry.
    func testOldMinuteRowKeepsTheCommaTitleTogether() {
        let stored = "Code — we also need to make the…, Safari — The New York Times - Breaking News, US News, World News and Videos, Microsoft Outlook — Inbox"
        XCTAssertEqual(AppList.parse(stored), [
            "Code — we also need to make the…",
            "Safari — The New York Times - Breaking News, US News, World News and Videos",
            "Microsoft Outlook — Inbox",
        ])
        XCTAssertEqual(AppList.appNames(stored), ["Code", "Safari", "Microsoft Outlook"])
    }

    /// Real task rows from the store. The fragments must never read as apps.
    func testRealBrokenRowsYieldNoPhantomApps() {
        XCTAssertEqual(AppList.appNames("Safari, US News, World News and Videos"), ["Safari"])
        XCTAssertEqual(AppList.appNames("Code, Safari, 9 September"), ["Code", "Safari"])
        XCTAssertEqual(AppList.appNames("Safari, the ‘Millennium’ Math Problem OpenAI Claims to"), ["Safari"])
    }

    func testCleanOldTaskRowStillReadsAsSeparateApps() {
        XCTAssertEqual(AppList.appNames("Code, Safari, Microsoft Outlook"), ["Code", "Safari", "Microsoft Outlook"])
    }

    /// An app named in full earlier in the row is recognised later on bare.
    func testAppNamedEarlierIsRecognisedBare() {
        let stored = "Google Chrome — Vendor Bills, Google Chrome"
        XCTAssertEqual(AppList.parse(stored), ["Google Chrome — Vendor Bills", "Google Chrome"])
    }

    // MARK: The readers

    /// Grouping and the task record read the same list the same way.
    func testTaskRecordDoesNotSplitTitlesOnCommas() {
        let stored = AppList.join(["Safari — The New York Times - Breaking News, US News, World News and Videos"])
        let m = MinuteSummary(minuteStart: Date(timeIntervalSince1970: 1_700_000_000), text: "Looked at Safari.",
                              apps: stored, keystrokes: 10, clicks: 2, shortcuts: "", fields: "", sourceCount: 0)
        let r = StoryWriter.taskRecord(minutes: [m], transfers: [])
        XCTAssertEqual(r.apps, ["Safari"], "\(r.apps)")
        XCTAssertEqual(Synthesizer.mergedApps([m]), ["Safari"])
        XCTAssertFalse(r.text.contains("US News\" "), r.text)
    }
}
