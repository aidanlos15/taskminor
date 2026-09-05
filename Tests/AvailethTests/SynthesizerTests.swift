import XCTest
@testable import Availeth

final class SynthesizerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func minute(_ offsetMin: Int, apps: String, keys: Int = 0, shortcuts: String = "", fields: String = "", text: String = "work") -> MinuteSummary {
        MinuteSummary(minuteStart: base.addingTimeInterval(Double(offsetMin) * 60), text: text,
                      apps: apps, keystrokes: keys, clicks: 0, shortcuts: shortcuts, fields: fields, sourceCount: 1)
    }

    // MARK: - Grouping

    func testConsecutiveSameAppMinutesGroupTogether() {
        let mins = [minute(0, apps: "Mail, Excel"), minute(1, apps: "Excel, Chrome"), minute(2, apps: "Chrome, Excel")]
        var cfg = Synthesizer.Config(); cfg.taskGraceSeconds = 0
        let (closed, _) = Synthesizer.groupMinutes(mins, now: base.addingTimeInterval(600), config: cfg)
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed[0].count, 3)
    }

    /// App change WITHOUT a time gap does NOT split — a cross-app workflow
    /// (Mail → Excel → ERP) must stay one task.
    func testAppChangeWithoutGapStaysOneTask() {
        let mins = [minute(0, apps: "Mail, Preview"), minute(1, apps: "Microsoft Excel"), minute(2, apps: "Google Chrome, NetSuite")]
        var cfg = Synthesizer.Config(); cfg.taskGraceSeconds = 0
        let (closed, _) = Synthesizer.groupMinutes(mins, now: base.addingTimeInterval(600), config: cfg)
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed[0].count, 3)
    }

    func testGapSplitsTasks() {
        // A 20-minute gap between minute 1 and minute 20 → two tasks.
        let mins = [minute(0, apps: "Excel"), minute(1, apps: "Excel"), minute(20, apps: "Excel"), minute(21, apps: "Excel")]
        var cfg = Synthesizer.Config(); cfg.taskGraceSeconds = 0
        let (closed, _) = Synthesizer.groupMinutes(mins, now: base.addingTimeInterval(3600), config: cfg)
        XCTAssertEqual(closed.count, 2)
    }

    func testMaxTaskLengthCaps() {
        let mins = (0..<13).map { minute($0, apps: "Excel") }
        var cfg = Synthesizer.Config(); cfg.taskGraceSeconds = 0; cfg.maxTaskMinutes = 10
        let (closed, _) = Synthesizer.groupMinutes(mins, now: base.addingTimeInterval(3600), config: cfg)
        XCTAssertEqual(closed.first?.count, 10)
    }

    /// A too-recent trailing run stays pending (not prematurely closed).
    func testRecentTrailingRunPending() {
        let now = base.addingTimeInterval(3 * 60) // minutes 0,1,2 are all within grace
        let mins = [minute(0, apps: "Excel"), minute(1, apps: "Excel"), minute(2, apps: "Excel")]
        let cfg = Synthesizer.Config() // grace 120s
        let (closed, pending) = Synthesizer.groupMinutes(mins, now: now, config: cfg)
        XCTAssertTrue(closed.isEmpty)
        XCTAssertEqual(pending.count, 3)
    }

    // MARK: - Minute context

    func testMinuteContextFusesSignals() {
        let start = base
        let spans = [
            ActivitySpan(bundleID: "com.microsoft.Excel", appName: "Microsoft Excel", windowTitle: "PO.xlsx",
                         start: start, end: start.addingTimeInterval(30), keystrokes: 20, clicks: 3,
                         shortcuts: "⌘C×2", fields: "PO [identifier]"),
        ]
        let narr = [SceneNarrative(timestamp: start.addingTimeInterval(10), appName: "Microsoft Excel", windowTitle: "PO.xlsx", text: "Searching a spreadsheet.")]
        let ctx = Synthesizer.buildMinuteContext(minute: start, narratives: narr, spans: spans, idleSeconds: 0, idleFractionForAway: 0.6)
        XCTAssertNotNil(ctx)
        XCTAssertFalse(ctx!.isAway)
        XCTAssertEqual(ctx!.keystrokes, 20)
        XCTAssertTrue(ctx!.prompt.contains("Searching a spreadsheet"))
        XCTAssertTrue(ctx!.prompt.contains("⌘C"))
    }

    func testIdleMinuteMarkedAway() {
        let ctx = Synthesizer.buildMinuteContext(minute: base, narratives: [], spans: [], idleSeconds: 55, idleFractionForAway: 0.6)
        XCTAssertNotNil(ctx)
        XCTAssertTrue(ctx!.isAway)
    }

    func testEmptyMinuteReturnsNil() {
        XCTAssertNil(Synthesizer.buildMinuteContext(minute: base, narratives: [], spans: [], idleSeconds: 0, idleFractionForAway: 0.6))
    }

    // MARK: - Automatable heuristic

    func testCopyPasteAcrossAppsScoresHigh() {
        let mins = [
            minute(0, apps: "Excel, Chrome", keys: 40, shortcuts: "⌘C×3, ⌘V×3, Tab×5", fields: "A [identifier], B [currency], C [identifier]"),
        ]
        XCTAssertTrue(Synthesizer.automatableAssessment(mins).hasPrefix("High"))
    }

    func testBrowsingScoresLow() {
        let mins = [minute(0, apps: "Chrome", keys: 5, shortcuts: "↓×3", fields: "")]
        XCTAssertTrue(Synthesizer.automatableAssessment(mins).hasPrefix("Low"))
    }

    // MARK: - Parsing

    func testParseTitleAndStory() {
        let raw = "TITLE: Invoice entry\nSTORY: The user copied a PO and pasted it into NetSuite. They submitted the bill."
        let (title, story) = Synthesizer.parseTitleAndStory(raw, fallbackApps: ["Chrome"])
        XCTAssertEqual(title, "Invoice entry")
        XCTAssertTrue(story.contains("copied a PO"))
    }

    func testParseFallsBackWhenUnformatted() {
        let (title, story) = Synthesizer.parseTitleAndStory("just a blob of text", fallbackApps: ["Excel"])
        XCTAssertEqual(title, "Excel workflow")
        XCTAssertEqual(story, "just a blob of text")
    }

    /// When the model emits only a TITLE, the story must NOT leak the "TITLE:"
    /// label — it falls back to the clean signal-derived sentence.
    func testParseTitleOnlyDoesNotLeakLabel() {
        let (title, story) = Synthesizer.parseTitleAndStory("TITLE: Some task", fallbackApps: ["Excel"], fallbackStory: "Worked across Excel.")
        XCTAssertEqual(title, "Some task")
        XCTAssertFalse(story.contains("TITLE"))
        XCTAssertEqual(story, "Worked across Excel.")
    }

    /// Multiple STORY lines are appended, not overwritten.
    func testParseMultipleStoryLines() {
        let raw = "TITLE: T\nSTORY: First sentence.\nSTORY: Second sentence."
        let (_, story) = Synthesizer.parseTitleAndStory(raw, fallbackApps: ["X"])
        XCTAssertTrue(story.contains("First sentence"))
        XCTAssertTrue(story.contains("Second sentence"))
    }

    /// A single low-activity minute is trivial (settled as noise, not a task).
    func testTrivialSingleMinute() {
        XCTAssertTrue(Synthesizer.isTrivial([minute(0, apps: "Slack", keys: 3)]))
        // A single high-activity minute is NOT trivial.
        XCTAssertFalse(Synthesizer.isTrivial([minute(0, apps: "Excel", keys: 120)]))
        // Two minutes are never trivial.
        XCTAssertFalse(Synthesizer.isTrivial([minute(0, apps: "Slack", keys: 3), minute(1, apps: "Slack", keys: 3)]))
    }

    /// Epoch floor lands on an exact :00 boundary and never rolls into the
    /// current incomplete minute.
    func testFloorToMinute() {
        // 1699999980 is a real minute boundary (divisible by 60).
        let d = Date(timeIntervalSince1970: 1_699_999_980 + 37.6)
        let floored = Synthesizer.floorToMinute(d)
        XCTAssertEqual(floored.timeIntervalSince1970, 1_699_999_980, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(floored, d)
        // Already on a boundary → unchanged.
        XCTAssertEqual(Synthesizer.floorToMinute(Date(timeIntervalSince1970: 1_699_999_980)).timeIntervalSince1970, 1_699_999_980, accuracy: 0.0001)
    }
}
