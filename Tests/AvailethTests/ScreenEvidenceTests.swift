import XCTest
@testable import Availeth

/// Says the text model is ready, and fails the test if anything asks it to
/// write. On a Mac with no vision model there are no scene narratives, and a
/// small text model handed window titles alone invents the work.
private final class WritingIsAMistake: SceneInterpreter {
    var displayName: String { "text only" }
    func isAvailable() async -> Bool { false }
    func isTextAvailable() async -> Bool { true }
    func narrate(pngData: Data, context: SceneContext) async -> String? { nil }
    func summarize(prompt: String, maxTokens: Int) async -> String? {
        XCTFail("the model must not be asked to write without screen narratives")
        return nil
    }
    func summarize(prompt: String, maxTokens: Int, stop: [String]) async -> String? {
        XCTFail("the model must not be asked to write without screen narratives")
        return nil
    }
}

final class ScreenEvidenceTests: XCTestCase {

    private func tempStore() -> Store {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("av-evidence-\(UUID().uuidString).sqlite")
        return Store(url: url)
    }

    /// Five minutes of work, no screenshots taken, so no narratives.
    private func seed(_ store: Store, now: Date) -> [Date] {
        var starts: [Date] = []
        for i in 0..<5 {
            let start = Synthesizer.floorToMinute(now.addingTimeInterval(Double(-12 + i) * 60))
            starts.append(start)
            _ = store.insert(ActivitySpan(bundleID: "com.microsoft.Excel", appName: "Microsoft Excel",
                                          windowTitle: "Purchase Orders.xlsx",
                                          start: start.addingTimeInterval(2), end: start.addingTimeInterval(55),
                                          isDemo: false, keystrokes: 120, clicks: 9,
                                          shortcuts: "⌘C×2, ⌘V×2", fields: "Amount"))
        }
        return starts
    }

    func testWithNoNarrativesTheMinuteIsThePlainEntry() async {
        let store = tempStore()
        let now = Date()
        let starts = seed(store, now: now)
        var cfg = Synthesizer.Config(); cfg.maxMinutesPerRun = 200
        await Synthesizer(store: store, interpreter: WritingIsAMistake(), config: cfg).run(now: now)

        let summaries = store.minuteSummaries(from: starts[0], to: now, demo: false)
            .filter { !$0.text.isEmpty }
        XCTAssertFalse(summaries.isEmpty)
        for m in summaries {
            let spans = store.spans(from: m.minuteStart, to: m.minuteStart.addingTimeInterval(60), demo: false)
            let record = StoryWriter.minuteRecord(spans: spans, transfers: [], narratives: [])
            XCTAssertEqual(m.text, StoryWriter.plainEntry(record))
        }
    }

    func testWithNoNarrativesTheTaskIsThePlainTitleAndStory() async {
        let store = tempStore()
        let now = Date()
        let starts = seed(store, now: now)
        var cfg = Synthesizer.Config(); cfg.maxMinutesPerRun = 200
        await Synthesizer(store: store, interpreter: WritingIsAMistake(), config: cfg).run(now: now)

        let tasks = store.taskSummaries(from: starts[0], to: now, demo: false)
        XCTAssertEqual(tasks.count, 1, "one run of minutes is one task")
        let task = tasks[0]

        let minutes = store.minuteSummaries(from: starts[0], to: now, demo: false)
            .filter { !$0.text.isEmpty }
        let record = StoryWriter.taskRecord(minutes: minutes, transfers: [])
        let (plainTitle, plainStory) = StoryWriter.acceptTitleAndStory(nil, record: record)
        XCTAssertEqual(task.title, plainTitle)
        XCTAssertEqual(task.title, StoryWriter.plainTitle(apps: record.apps))
        XCTAssertEqual(task.text, NarrativeSanitizer.scrub(plainStory))
        XCTAssertEqual(task.text, NarrativeSanitizer.scrub(StoryWriter.plainStory(record)))
    }

    /// The rule, on its own, so it is pinned without running a whole store.
    func testTheModelWritesOnlyWhenTheScreenWasDescribed() {
        XCTAssertFalse(Synthesizer.mayWriteProse(modelReady: true, sceneNarratives: 0))
        XCTAssertFalse(Synthesizer.mayWriteProse(modelReady: false, sceneNarratives: 4))
        XCTAssertTrue(Synthesizer.mayWriteProse(modelReady: true, sceneNarratives: 1))
    }
}
