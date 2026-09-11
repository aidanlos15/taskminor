import XCTest
@testable import Availeth

/// A scripted local model: canned replies, a call counter, and an availability switch.
final class FakeInterpreter: SceneInterpreter {
    var displayName = "fake (local)"
    var available = true
    var replies: [String?] = []
    var calls = 0
    var lastPrompt = ""
    init(replies: [String?] = []) { self.replies = replies }
    func isAvailable() async -> Bool { available }
    func narrate(pngData: Data, context: SceneContext) async -> String? { nil }
    func summarize(prompt: String, maxTokens: Int) async -> String? {
        calls += 1
        lastPrompt = prompt
        return replies.isEmpty ? nil : replies.removeFirst()
    }
}

final class IntentLabelerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private var now: Date { base.addingTimeInterval(2 * 3600) }

    private func span(_ app: String, _ title: String, atMin: Double, durMin: Double = 3, bundle: String = "com.x", keys: Int = 40) -> ActivitySpan {
        let s = base.addingTimeInterval(atMin * 60)
        return ActivitySpan(bundleID: bundle, appName: app, windowTitle: title, start: s, end: s.addingTimeInterval(durMin * 60), keystrokes: keys)
    }
    private func narr(_ app: String, _ title: String, atMin: Double, _ text: String) -> SceneNarrative {
        SceneNarrative(timestamp: base.addingTimeInterval(atMin * 60), appName: app, windowTitle: title, text: text)
    }

    // MARK: Sessions

    func testSessioniseSplitsOnGapAndOrdersNewestFirst() {
        let spans = [
            span("Claude", "Claude", atMin: 0), span("Claude", "Claude", atMin: 3),
            span("Claude", "Claude", atMin: 20), span("Claude", "Claude", atMin: 23),
            span("Google Chrome", "Claude - Google Chrome - Aidan", atMin: 24),
        ]
        let sessions = IntentLabeler.sessionise(spans, gap: 300)
        XCTAssertEqual(sessions.count, 2, "the Claude tab in Chrome at minute 24 joins the Claude sitting at 20–26")
        XCTAssertEqual(sessions.first?.start, base.addingTimeInterval(20 * 60), "newest first")
        XCTAssertEqual(sessions.first?.spans.count, 3)
        XCTAssertEqual(sessions.map(\.unit), ["Claude", "Claude"])
        XCTAssertEqual(sessions.last?.spans.count, 2)
    }

    // MARK: Parsing

    func testParseMatchTitleAndRejects() {
        let existing = ["Debug a Swift build error"]
        XCTAssertEqual(IntentLabeler.parse("MATCH: 0\nTITLE: \"Draft the hotel profitability model.\"", existing: existing, unit: "Claude")?.title, "Draft the hotel profitability model")
        XCTAssertNil(IntentLabeler.parse("MATCH: 0\nTITLE: Draft the hotel profitability model.", existing: existing, unit: "Claude")?.matched)
        let m = IntentLabeler.parse("**MATCH:** 1\n**TITLE:** Fixing build", existing: existing, unit: "Claude")
        XCTAssertEqual(m?.matched, "Debug a Swift build error")
        XCTAssertEqual(m?.title, "Fixing build")
        XCTAssertEqual(IntentLabeler.parse("MATCH: 1\nTITLE:", existing: existing, unit: "Claude")?.title, "Debug a Swift build error", "a match with no title takes the existing title")
        XCTAssertEqual(IntentLabeler.parse("MATCH: 7\nTITLE: Compare AI model capabilities", existing: existing, unit: "Claude")?.matched, nil, "out-of-range match is ignored")
        XCTAssertEqual(IntentLabeler.parse("Compare AI model capabilities", existing: [], unit: "Claude")?.title, "Compare AI model capabilities", "bare title without labels")
        XCTAssertNil(IntentLabeler.parse("MATCH: 0\nTITLE:", existing: [], unit: "Claude"))
        XCTAssertNil(IntentLabeler.parse("TITLE: The screenshot shows a chat window", existing: [], unit: "Claude"))
        XCTAssertNil(IntentLabeler.parse("TITLE: Claude", existing: [], unit: "Claude"), "the unit name is not a task")
        XCTAssertNil(IntentLabeler.parse("TITLE: Unknown", existing: [], unit: "Claude"))
        XCTAssertNil(IntentLabeler.parse(nil, existing: [], unit: "Claude"))
        // An explicit empty TITLE stays empty whatever explanation follows it.
        XCTAssertNil(IntentLabeler.parse("MATCH: 0\nTITLE:\nThe evidence does not show what the work was.", existing: [], unit: "Claude"))
        XCTAssertNil(IntentLabeler.parse("MATCH: 0\nTITLE:\nI cannot determine the task from this.", existing: [], unit: "Claude"))
        XCTAssertNil(IntentLabeler.parse("I'm sorry, but there isn't enough information to name this", existing: [], unit: "Claude"))
        XCTAssertNil(IntentLabeler.parse("There is no clear task here", existing: [], unit: "Claude"))
        // Legitimate titles that merely contain a rejected word still pass.
        XCTAssertEqual(IntentLabeler.parse("TITLE: Set up screen recording for the demo", existing: [], unit: "Zoom")?.title, "Set up screen recording for the demo")
        XCTAssertEqual(IntentLabeler.parse("TITLE: Plan the training session agenda", existing: [], unit: "Notes")?.title, "Plan the training session agenda")
        XCTAssertEqual(IntentLabeler.parse("TITLE: The user is drafting an email to a supplier about invoice [id]", existing: [], unit: "Claude")?.title,
                       "Drafting an email to a supplier about invoice")
    }

    func testCleanTitleCapsOnAWordBoundary() {
        let long = "Reconcile every outstanding supplier invoice against the purchase order ledger before month end closes"
        let t = IntentLabeler.cleanTitle(long, unit: "Excel")
        XCTAssertNil(t, "13 words is too long to be a title")
        let twelve = "Reconcile every outstanding supplier invoice against the purchase order ledger before month"
        let c = IntentLabeler.cleanTitle(twelve, unit: "Excel")!
        XCTAssertLessThanOrEqual(c.count, 60)
        XCTAssertTrue(twelve.hasPrefix(c), "cut must fall on a word: \(c)")
    }

    // MARK: Prompt

    func testPromptCarriesEvidenceAndStaysBounded() {
        let s = IntentLabeler.Session(unit: "Claude", cleanTitle: "Claude", spans: [span("Claude", "Claude", atMin: 0, keys: 300)])
        let narratives = (0..<40).map { i in narr("Claude", "Claude", atMin: Double(i) / 20, String(repeating: "x", count: 200) + " \(i)") }
        let ev = IntentLabeler.Evidence(narratives: narratives, minutes: [])
        let p = IntentLabeler.prompt(session: s, evidence: ev, existing: (1...12).map { "Existing task number \($0)" })
        XCTAssertTrue(p.contains("App: Claude"))
        XCTAssertTrue(p.contains("300 keystrokes"))
        XCTAssertTrue(p.contains("12. Existing task number 12"))
        XCTAssertTrue(p.hasSuffix("TITLE: <the title>"))
        XCTAssertLessThan(p.count, 6000, "evidence budget: got \(p.count) chars")
        XCTAssertEqual(p.components(separatedBy: "\n[").count - 1, 8, "eight narratives, evenly spread")
        XCTAssertTrue(p.contains(" 39"), "the last narrative is always included")
    }

    // MARK: End to end

    func testLabelsGenericSessionsAndPassesGoodTitlesThrough() async {
        let store = Store.inMemory()
        for s in [
            span("Claude", "Claude", atMin: 0), span("Claude", "Claude", atMin: 3),
            span("Claude", "Claude", atMin: 20), span("Claude", "Claude", atMin: 23),
            span("Google Chrome", "Smart campaign - Ring of Kerry Hotel - Google Ads - Google Chrome - Ring", atMin: 30),
        ] { store.insert(s) }
        store.insertNarrative(narr("Claude", "Claude", atMin: 1, "The user asks Claude how to structure a hotel profitability model."))
        store.insertNarrative(narr("Claude", "Claude", atMin: 21, "The user asks Claude to debug a Swift build error about a missing type."))

        let fake = FakeInterpreter(replies: ["MATCH: 0\nTITLE: Debug a Swift build error", "MATCH: 0\nTITLE: Structure a hotel profitability model"])
        let labeler = IntentLabeler(store: store, interpreter: fake)
        await labeler.run(now: now)

        let labels = store.spanLabels(from: .distantPast, to: .distantFuture, demo: false)
        XCTAssertEqual(labels.count, 5, "every closed span gets a row")
        XCTAssertEqual(fake.calls, 2, "one call per generic session, none for the Google Ads tab")
        let ads = labels.values.first { $0.unit == "Google Ads" }
        XCTAssertEqual(ads?.source, .title)
        XCTAssertEqual(ads?.canon, "Smart campaign - Ring of Kerry Hotel - Google Ads")
        let canons = Set(labels.values.filter { $0.unit == "Claude" }.map(\.canon))
        XCTAssertEqual(canons, ["Debug a Swift build error", "Structure a hotel profitability model"])
        XCTAssertTrue(labels.values.filter { $0.unit == "Claude" }.allSatisfy { $0.source == .model })
        XCTAssertTrue(fake.lastPrompt.contains("hotel profitability"), "the newest session was asked first with its own evidence")

        // Idempotent: nothing left to do, no further calls.
        await labeler.run(now: now.addingTimeInterval(90))
        XCTAssertEqual(fake.calls, 2)
        XCTAssertEqual(store.spanLabels(from: .distantPast, to: .distantFuture, demo: false).count, 5)
    }

    func testOfflineWritesOnlyDeterministicRowsAndRetriesLater() async {
        let store = Store.inMemory()
        store.insert(span("Claude", "Claude", atMin: 0))
        store.insert(span("Microsoft Excel", "Purchase Orders.xlsx", atMin: 10))
        store.insertNarrative(narr("Claude", "Claude", atMin: 1, "Asking about a hotel model."))
        let fake = FakeInterpreter(replies: ["MATCH: 0\nTITLE: Structure a hotel profitability model"])
        fake.available = false
        let labeler = IntentLabeler(store: store, interpreter: fake)
        await labeler.run(now: now)
        var labels = store.spanLabels(from: .distantPast, to: .distantFuture, demo: false)
        XCTAssertEqual(labels.count, 1, "only the Excel passthrough is written while the model is down")
        XCTAssertEqual(labels.values.first?.source, .title)
        XCTAssertEqual(fake.calls, 0)

        fake.available = true
        await labeler.run(now: now.addingTimeInterval(90))
        labels = store.spanLabels(from: .distantPast, to: .distantFuture, demo: false)
        XCTAssertEqual(labels.count, 2)
        XCTAssertEqual(labels.values.first { $0.unit == "Claude" }?.canon, "Structure a hotel profitability model")
    }

    func testTransportFailureLeavesSessionForNextTick() async {
        let store = Store.inMemory()
        store.insert(span("Claude", "Claude", atMin: 0))
        store.insertNarrative(narr("Claude", "Claude", atMin: 1, "Asking about a hotel model."))
        let fake = FakeInterpreter(replies: [nil, "MATCH: 0\nTITLE: Structure a hotel profitability model"])
        let labeler = IntentLabeler(store: store, interpreter: fake)
        await labeler.run(now: now)
        XCTAssertEqual(store.spanLabelCount(demo: false), 0, "a nil reply is a transport failure, not an answer")
        await labeler.run(now: now.addingTimeInterval(90))
        XCTAssertEqual(store.spanLabels(from: .distantPast, to: .distantFuture, demo: false).values.first?.canon, "Structure a hotel profitability model")
        XCTAssertEqual(fake.calls, 2)
    }

    func testNoEvidenceAndGarbageRepliesSettleHonestly() async {
        let store = Store.inMemory()
        store.insert(span("Claude", "Claude", atMin: 0))                          // no narrative at all
        store.insert(span("Claude", "Claude", atMin: 20))
        store.insertNarrative(narr("Claude", "Claude", atMin: 21, "Something on screen."))
        let fake = FakeInterpreter(replies: ["TITLE: The screenshot shows a chat window"])
        let labeler = IntentLabeler(store: store, interpreter: fake)
        await labeler.run(now: now)
        let labels = store.spanLabels(from: .distantPast, to: .distantFuture, demo: false).values
        XCTAssertEqual(labels.count, 2)
        XCTAssertTrue(labels.allSatisfy { $0.source == .fallback && $0.canon == "Claude" }, "\(labels)")
        XCTAssertEqual(fake.calls, 1, "the empty-evidence session never reaches the model")
    }

    func testNeighbourAdoptionAndGraceWindow() async {
        let store = Store.inMemory()
        store.insert(span("Claude", "Claude", atMin: 0))
        store.insertNarrative(narr("Claude", "Claude", atMin: 1, "Asking about a hotel model."))
        let fake = FakeInterpreter(replies: ["MATCH: 0\nTITLE: Structure a hotel profitability model"])
        let labeler = IntentLabeler(store: store, interpreter: fake)
        await labeler.run(now: now)
        XCTAssertEqual(fake.calls, 1)

        // A refocus on the same window two minutes later, still inside the grace window: waits.
        let late = span("Claude", "Claude", atMin: 5, durMin: 1)
        store.insert(late)
        await labeler.run(now: base.addingTimeInterval(6 * 60 + 30))
        XCTAssertEqual(store.spanLabelCount(demo: false), 1, "a session that may still grow is not named yet")

        // Once closed, it adopts the neighbour's label without a model call.
        await labeler.run(now: base.addingTimeInterval(20 * 60))
        let labels = store.spanLabels(from: .distantPast, to: .distantFuture, demo: false).values
        XCTAssertEqual(labels.count, 2)
        XCTAssertEqual(Set(labels.map(\.canon)), ["Structure a hotel profitability model"])
        XCTAssertEqual(Set(labels.map(\.sessionKey)).count, 1, "same sitting")
        XCTAssertEqual(fake.calls, 1)
    }

    /// A sitting named "Claude" for lack of evidence is renamed when its second
    /// half brings the evidence — one sitting, one title.
    func testLaterHalfRenamesAFallbackNeighbour() async {
        let store = Store.inMemory()
        store.insert(span("Claude", "Claude", atMin: 0))                 // no narrative yet
        let fake = FakeInterpreter(replies: ["MATCH: 0\nTITLE: Structure a hotel profitability model"])
        let labeler = IntentLabeler(store: store, interpreter: fake)
        await labeler.run(now: base.addingTimeInterval(10 * 60))
        XCTAssertEqual(store.spanLabels(from: .distantPast, to: .distantFuture, demo: false).values.first?.source, .fallback)

        store.insert(span("Claude", "Claude", atMin: 4))                 // within the gap
        store.insertNarrative(narr("Claude", "Claude", atMin: 5, "Asking about a hotel model."))
        await labeler.run(now: base.addingTimeInterval(20 * 60))
        let labels = store.spanLabels(from: .distantPast, to: .distantFuture, demo: false).values
        XCTAssertEqual(labels.count, 2)
        XCTAssertEqual(Set(labels.map(\.canon)), ["Structure a hotel profitability model"])
        XCTAssertEqual(Set(labels.map(\.source)), [.model])
        XCTAssertEqual(Set(labels.map(\.sessionKey)).count, 1, "the two halves are one sitting")
        XCTAssertEqual(fake.calls, 1)
    }

    /// Minute notes about other apps are not evidence for this session.
    func testMinuteNotesMustMentionTheApp() async {
        let store = Store.inMemory()
        store.insert(span("Claude", "Claude", atMin: 0))
        store.insertMinuteSummary(MinuteSummary(minuteStart: base, text: "Editing a budget spreadsheet.", apps: "Excel", keystrokes: 50, clicks: 3, shortcuts: "", fields: "", sourceCount: 1))
        let fake = FakeInterpreter(replies: ["MATCH: 0\nTITLE: Edit the budget spreadsheet"])
        let labeler = IntentLabeler(store: store, interpreter: fake)
        await labeler.run(now: now)
        XCTAssertEqual(fake.calls, 0, "nothing mentioned Claude — no call, honest fallback")
        XCTAssertEqual(store.spanLabels(from: .distantPast, to: .distantFuture, demo: false).values.first?.source, .fallback)
    }

    func testExistingTitlesAreOfferedAndMerged() async {
        let store = Store.inMemory()
        store.insert(span("Claude", "Claude", atMin: 0))
        store.insert(span("Claude", "Claude", atMin: 20))
        store.insertNarrative(narr("Claude", "Claude", atMin: 1, "Debugging a build."))
        store.insertNarrative(narr("Claude", "Claude", atMin: 21, "Debugging a build again."))
        // Newest first: session at 20 is named, then the session at 0 is offered it and matches.
        let fake = FakeInterpreter(replies: ["MATCH: 0\nTITLE: Debug a Swift build error", "MATCH: 1\nTITLE: Fix the Swift build"])
        let labeler = IntentLabeler(store: store, interpreter: fake)
        await labeler.run(now: now)
        XCTAssertTrue(fake.lastPrompt.contains("1. Debug a Swift build error"), "the existing title was offered")
        let labels = store.spanLabels(from: .distantPast, to: .distantFuture, demo: false).values
        XCTAssertEqual(Set(labels.map(\.canon)), ["Debug a Swift build error"], "both sittings batch into one task")
        XCTAssertEqual(Set(labels.map(\.intent)), ["Debug a Swift build error", "Fix the Swift build"], "what the model said is kept")
    }
}
