import XCTest
@testable import Availeth

/// Storyline only sends a frame to the local vision model when the user pasted
/// or filled in a field. Everything else - periodic samples, app switches,
/// copies, cuts, saves - is skipped, because the model costs a CPU core for
/// about fifteen seconds a frame.
final class NarrationTriggerTests: XCTestCase {

    func testOnlyPastedAndFilledAFieldAreNarrated() {
        XCTAssertEqual(CaptureEngine.narratedTriggers, ["Pasted", "Filled a field"])
        XCTAssertTrue(CaptureEngine.shouldNarrate(mode: .storyline, reason: "Pasted"))
        XCTAssertTrue(CaptureEngine.shouldNarrate(mode: .storyline, reason: "Filled a field"))
        for reason in ["Copied", "Cut", "Saved", "Switched to Code", ""] {
            XCTAssertFalse(CaptureEngine.shouldNarrate(mode: .storyline, reason: reason), reason)
        }
    }

    func testThumbnailsAreUnaffectedAndOffCapturesNothing() {
        for reason in ["Copied", "Switched to Code", ""] {
            XCTAssertTrue(CaptureEngine.shouldNarrate(mode: .thumbnails, reason: reason), reason)
            XCTAssertFalse(CaptureEngine.shouldNarrate(mode: .off, reason: reason), reason)
        }
    }
}

/// A text model that is ready but declines to write, so the card falls back to
/// the plain story. That is the path a Mac with no text model takes too.
private final class SilentInterpreter: SceneInterpreter {
    var displayName: String { "silent" }
    func isAvailable() async -> Bool { true }
    func isTextAvailable() async -> Bool { true }
    func narrate(pngData: Data, context: SceneContext) async -> String? { nil }
    func summarize(prompt: String, maxTokens: Int) async -> String? { nil }
    func summarize(prompt: String, maxTokens: Int, stop: [String]) async -> String? { nil }
}

/// What the screen showed has to reach the task card. Before this, a card read
/// as app names and typing volume and said nothing about the work.
final class TaskNarrativeTests: XCTestCase {

    private func minute(_ base: Date, _ i: Int) -> MinuteSummary {
        MinuteSummary(minuteStart: base.addingTimeInterval(Double(i) * 60), text: "Worked in Code.",
                      apps: "Code — Message input", keystrokes: 90, clicks: 5,
                      shortcuts: "⌘V×1", fields: "Message", sourceCount: 1)
    }

    private func narrative(_ base: Date, _ i: Int, _ text: String) -> SceneNarrative {
        SceneNarrative(timestamp: base.addingTimeInterval(Double(i) * 60 + 20), appName: "Code",
                       windowTitle: "Message input", text: text, trigger: "Pasted")
    }

    func testPlainStoryLeadsWithTheScreenNotes() {
        let base = Synthesizer.floorToMinute(Date().addingTimeInterval(-3600))
        let mins = (0..<5).map { minute(base, $0) }
        let narrs = [
            narrative(base, 0, "Pasted a field adjustment email into the Message input in Code. It named job code 300."),
            narrative(base, 1, "Pasted a field adjustment email into the Message input in Code. It named job code 300."),
            narrative(base, 3, "Typed three hours against job code 300 in the Message input.")
        ]
        let r = StoryWriter.taskRecord(minutes: mins, transfers: [], narratives: narrs)
        XCTAssertTrue(r.text.contains("What the screen showed, newest first:"), r.text)
        XCTAssertEqual(r.sceneNotes.count, 2, "the two identical notes collapse into one")

        let story = StoryWriter.plainStory(r)
        XCTAssertTrue(story.hasPrefix("Typed three hours against job code 300 in the Message input."), story)
        XCTAssertTrue(story.contains("Pasted a field adjustment email into the Message input in Code."), story)
        XCTAssertTrue(story.contains("mostly in Code"), story)
        XCTAssertLessThanOrEqual(story.count, 500)
    }

    func testWithNoNarrativesTheStoryIsUnchanged() {
        let base = Synthesizer.floorToMinute(Date().addingTimeInterval(-3600))
        let mins = (0..<5).map { minute(base, $0) }
        let story = StoryWriter.plainStory(StoryWriter.taskRecord(minutes: mins, transfers: []))
        XCTAssertTrue(story.hasPrefix("A few minutes, mostly in Code"), story)
    }

    func testCapStoryStopsAtRoughlyFiveHundredCharacters() {
        let long = String(repeating: "Pasted a value into the Message input in Code. ", count: 30)
        XCTAssertLessThanOrEqual(StoryWriter.capStory(long).count, 500)
    }

    func testTaskSummaryCarriesTheNarrativeText() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("av-narr-\(UUID().uuidString).sqlite")
        let store = Store(url: url)
        let now = Date()
        let base = Synthesizer.floorToMinute(now.addingTimeInterval(-12 * 60))
        for i in 0..<5 {
            let start = base.addingTimeInterval(Double(i) * 60)
            _ = store.insert(ActivitySpan(bundleID: "com.microsoft.VSCode", appName: "Code",
                                          windowTitle: "Message input", start: start.addingTimeInterval(2),
                                          end: start.addingTimeInterval(55), isDemo: false,
                                          keystrokes: 120, clicks: 9, shortcuts: "⌘V×2", fields: "Message"))
            _ = store.insertNarrative(narrative(base, i, "Pasted a field adjustment email for job code 300 into the Message input in Code."))
        }
        var cfg = Synthesizer.Config(); cfg.maxMinutesPerRun = 200
        await Synthesizer(store: store, interpreter: SilentInterpreter(), config: cfg).run(now: now)

        let tasks = store.taskSummaries(from: base, to: now, demo: false)
        XCTAssertEqual(tasks.count, 1)
        let text = tasks[0].text
        XCTAssertTrue(text.contains("job code 300"), text)
        XCTAssertTrue(text.contains("Message input"), text)
        XCTAssertLessThanOrEqual(text.count, 500)
    }
}
