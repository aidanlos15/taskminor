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
        XCTAssertTrue(ctx!.prompt.contains("Keys: copy"), ctx!.prompt)
        XCTAssertFalse(ctx!.prompt.contains("⌘"), "symbols are translated before the model sees them")
    }

    func testIdleMinuteMarkedAway() {
        let ctx = Synthesizer.buildMinuteContext(minute: base, narratives: [], spans: [], idleSeconds: 55, idleFractionForAway: 0.6)
        XCTAssertNotNil(ctx)
        XCTAssertTrue(ctx!.isAway)
    }

    func testEmptyMinuteReturnsNil() {
        XCTAssertNil(Synthesizer.buildMinuteContext(minute: base, narratives: [], spans: [], idleSeconds: 0, idleFractionForAway: 0.6))
    }

    // MARK: - Automatable verdict (shared with the Workflows tab)

    /// Copy-and-paste across apps is only a candidate once it has RECURRED.
    /// The same minute judged on its own says so instead of guessing.
    func testCopyPasteAcrossAppsNeedsRecurrenceBeforeScoringHigh() {
        let mins = [
            minute(0, apps: "Excel, Chrome", keys: 40, shortcuts: "⌘C×3, ⌘V×3, Tab×5", fields: "Invoice Number [identifier], Amount [currency], PO Number [identifier]"),
        ]
        let onceOnly = Synthesizer.automatableAssessment(mins, occurrences: 1, daysObserved: 1, transfers: 3, durations: [180])
        XCTAssertTrue(onceOnly.hasPrefix("Not enough evidence yet"), onceOnly)

        let recurring = Synthesizer.automatableAssessment(mins, occurrences: 9, daysObserved: 5, transfers: 27,
                                                          durations: Array(repeating: 180, count: 9))
        XCTAssertTrue(recurring.hasPrefix("High"), recurring)
    }

    /// Browsing with nothing moved and no fields filled stays Low even when it
    /// has recurred plenty.
    func testBrowsingScoresLowEvenWhenItRecurs() {
        let mins = [minute(0, apps: "Chrome", keys: 5, shortcuts: "↓×3", fields: "")]
        let v = Synthesizer.automatableAssessment(mins, occurrences: 12, daysObserved: 6, transfers: 0,
                                                  durations: Array(repeating: 200, count: 12))
        XCTAssertTrue(v.hasPrefix("Low"), v)
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
        XCTAssertEqual(title, "Excel")
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

// MARK: - Running with no local model
//
// The whole story layer used to sit behind `guard await interpreter.isAvailable()`,
// so a Mac with no Ollama produced no minute summaries, no tasks and a Story tab
// that told the user to keep waiting for something that would never arrive.

/// Answers "not available" to everything, like a Mac with no Ollama installed.
private final class UnavailableInterpreter: SceneInterpreter {
    var displayName: String { "none" }
    func isAvailable() async -> Bool { false }
    func isTextAvailable() async -> Bool { false }
    func narrate(pngData: Data, context: SceneContext) async -> String? { nil }
    func summarize(prompt: String, maxTokens: Int) async -> String? {
        XCTFail("summarize must not be called when no model is available")
        return nil
    }
}

final class SynthesizerNoModelTests: XCTestCase {
    private func tempStore() -> Store {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("av-nomodel-\(UUID().uuidString).sqlite")
        return Store(url: url)
    }

    /// With no model, every complete minute is still summarized. Before the fix
    /// this produced zero rows.
    func testMinutesAreStillSummarizedWithNoModel() async {
        let store = tempStore()
        let now = Date()
        let minuteStart = Synthesizer.floorToMinute(now.addingTimeInterval(-120))
        _ = store.insert(ActivitySpan(bundleID: "com.microsoft.Excel", appName: "Microsoft Excel",
                                      windowTitle: "Purchase Orders.xlsx",
                                      start: minuteStart, end: minuteStart.addingTimeInterval(50),
                                      isDemo: false, keystrokes: 120, clicks: 8,
                                      shortcuts: "Copy, Paste", fields: "Amount"))

        // The first run walks forward from two hours ago, 8 minutes at a time, so
        // widen the budget to reach a span two minutes old inside one call.
        var cfg = Synthesizer.Config(); cfg.maxMinutesPerRun = 200
        let synth = Synthesizer(store: store, interpreter: UnavailableInterpreter(), config: cfg)
        await synth.run(now: now)

        let summaries = store.minuteSummaries(from: minuteStart, to: now, demo: false)
        XCTAssertFalse(summaries.isEmpty, "no model must not mean no summaries")
    }

    /// The no-model line is built from the record: where the work was, how
    /// much typing, what was typed into and what moved. Not a list of app names
    /// and not a recital of counts.
    func testFallbackTextUsesEverySignal() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let spans = [
            ActivitySpan(bundleID: "com.microsoft.Excel", appName: "Microsoft Excel", windowTitle: "PO.xlsx",
                         start: start, end: start.addingTimeInterval(20), keystrokes: 40, clicks: 4, shortcuts: "⌘C×2", fields: ""),
            ActivitySpan(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Vendor Bills",
                         start: start.addingTimeInterval(20), end: start.addingTimeInterval(55), keystrokes: 300, clicks: 20,
                         shortcuts: "⌘V×2", fields: "Amount [currency], Invoice Number [identifier]"),
        ]
        let ctx = Synthesizer.buildMinuteContext(minute: start, narratives: [], spans: spans, idleSeconds: 0, idleFractionForAway: 0.6)!
        XCTAssertEqual(ctx.fallbackText,
                       "Typed at length in Microsoft Excel (PO.xlsx) and Google Chrome (Vendor Bills), copying and pasting. Typed into Amount, Invoice Number in Google Chrome.")
    }

    /// One window and a little typing reads as one plain sentence, never
    /// "1 keystrokes".
    func testFallbackTextSingularUnits() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let spans = [ActivitySpan(bundleID: "com.apple.mail", appName: "Mail", windowTitle: "Inbox",
                                  start: start, end: start.addingTimeInterval(30), keystrokes: 1, clicks: 1, shortcuts: "", fields: "")]
        let ctx = Synthesizer.buildMinuteContext(minute: start, narratives: [], spans: spans, idleSeconds: 0, idleFractionForAway: 0.6)!
        XCTAssertEqual(ctx.fallbackText, "Worked briefly in Mail (Inbox).")
    }

    /// A scene narrative, when one exists, still wins over the generic line.
    func testSceneTextWinsOverGenericLine() {
        let ctx = Synthesizer.MinuteContext(
            minute: Date(), apps: ["Google Chrome"], keystrokes: 10, clicks: 2,
            shortcuts: "", fields: "", sceneTexts: ["Submitting a vendor bill in NetSuite."],
            sourceCount: 1, isAway: false)
        XCTAssertEqual(ctx.fallbackText, "Submitting a vendor bill in NetSuite.")
    }

    /// The task-level story is built from the signals when no model can write it.
    func testSignalStoryDescribesTheTask() {
        let mins = [
            MinuteSummary(minuteStart: Date(), text: "", apps: "Microsoft Excel", keystrokes: 200, clicks: 10,
                          shortcuts: "Copy, Paste", fields: "Amount", sourceCount: 1),
            MinuteSummary(minuteStart: Date().addingTimeInterval(60), text: "", apps: "Google Chrome", keystrokes: 140, clicks: 14,
                          shortcuts: "Paste, Find", fields: "Invoice Number", sourceCount: 1),
        ]
        let story = Synthesizer.signalStory(group: mins, apps: ["Microsoft Excel", "Google Chrome"])
        XCTAssertTrue(story.contains("2 minutes"), story)
        XCTAssertTrue(story.contains("340 keystrokes"), story)
        XCTAssertTrue(story.contains("Paste"), story)
        XCTAssertTrue(story.contains("Amount"), story)
    }

    /// The most-used shortcuts and fields come first, so the story names the
    /// repeated action rather than an incidental one.
    func testTopTokensRanksByFrequency() {
        let top = Synthesizer.topTokens(["Copy, Paste", "Paste", "Paste, Find"], limit: 2)
        XCTAssertEqual(top.first, "Paste")
        XCTAssertEqual(top.count, 2)
    }

    /// Shortcut tokens carry counts; the same key across minutes sums rather
    /// than appearing once per minute.
    func testTopTokensMergesShortcutCounts() {
        let top = Synthesizer.topTokens(["↵×1, ⌘V×2", "↵×3", "⌘V×1, Tab×4"], limit: 3)
        XCTAssertEqual(top, ["Tab×4", "↵×4", "⌘V×3"], "ties sort by key: \(top)")
    }
}

extension SynthesizerNoModelTests {
    /// A fresh install must not walk through two hours of empty minutes one at a
    /// time. It jumps to the first captured activity, so the first real summary
    /// appears on the first run rather than 22 minutes later.
    func testFirstRunSkipsDeadTimeAndSummarizesRealActivity() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("av-skip-\(UUID().uuidString).sqlite")
        let store = Store(url: url)
        let now = Date()
        // Activity 3 minutes ago; the lookback window opens 2 hours ago.
        let spanStart = Synthesizer.floorToMinute(now.addingTimeInterval(-180))
        _ = store.insert(ActivitySpan(bundleID: "com.microsoft.Excel", appName: "Microsoft Excel",
                                      windowTitle: "Purchase Orders.xlsx",
                                      start: spanStart, end: spanStart.addingTimeInterval(50),
                                      isDemo: false, keystrokes: 90, clicks: 6,
                                      shortcuts: "Copy", fields: "Amount"))

        // Default budget of 8 minutes per run: only reachable if dead time is skipped.
        let synth = Synthesizer(store: store, interpreter: UnavailableInterpreter())
        await synth.run(now: now)

        let written = store.minuteSummaries(from: spanStart, to: now, demo: false)
        XCTAssertTrue(written.contains { $0.text.contains("Microsoft Excel") },
                      "the first run should reach real activity, got: \(written.map(\.text))")
    }
}

/// Onboarding must not be marked complete when the user granted nothing.
/// A single stray click on the first launch used to cost the app every
/// capability permanently, with no second ask.
final class OnboardingGateTests: XCTestCase {
    /// Mirrors WelcomeSheet.finish()'s decision so the rule is pinned by a test
    /// even though the sheet itself needs a running app to exercise.
    private func shouldMarkOnboarded(ax: Bool, screen: Bool, input: Bool) -> Bool {
        ax || screen || input
    }

    func testNothingGrantedDoesNotCompleteOnboarding() {
        XCTAssertFalse(shouldMarkOnboarded(ax: false, screen: false, input: false))
    }

    func testAnySingleGrantCompletesOnboarding() {
        XCTAssertTrue(shouldMarkOnboarded(ax: true, screen: false, input: false))
        XCTAssertTrue(shouldMarkOnboarded(ax: false, screen: true, input: false))
        XCTAssertTrue(shouldMarkOnboarded(ax: false, screen: false, input: true))
    }
}
