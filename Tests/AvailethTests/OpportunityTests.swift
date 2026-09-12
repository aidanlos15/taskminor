import XCTest
@testable import Availeth

final class OpportunityTests: XCTestCase {
    private let base = Date().addingTimeInterval(-2 * 86400)

    // MARK: Parsing

    func testParseKindsAndFields() {
        let raw = "KIND: APP\nBUILD: A rota app: shifts, availability requests and confirmations in one place.\nWHY: The rota is a spreadsheet and availability comes by email.\nEach reply is keyed in by hand.\nDATA: staff, shifts, availability, Weeks\nCONFIDENCE: High"
        let o = OpportunityAssessor.parse(raw, key: "wf:x", evidence: 6, model: "m")!
        XCTAssertEqual(o.kind, .customApp)
        XCTAssertEqual(o.headline, "A rota app: shifts, availability requests and confirmations in one place")
        XCTAssertEqual(o.rationale, "The rota is a spreadsheet and availability comes by email. Each reply is keyed in by hand.")
        XCTAssertEqual(o.entities, ["staff", "shifts", "availability", "weeks"])
        XCTAssertEqual(o.confidence, "high")
        XCTAssertEqual(o.evidence, 6)
        XCTAssertEqual(OpportunityAssessor.parse("**Kind**: Integration\n**Build**: Post bills into NetSuite", key: "k", evidence: 1, model: "m")?.kind, .integration)
        XCTAssertEqual(OpportunityAssessor.parse("KIND: streamline", key: "k", evidence: 1, model: "m")?.headline, Opportunity.Kind.streamline.title, "a missing BUILD falls back to the kind's title")
        XCTAssertEqual(OpportunityAssessor.parse("KIND: MANUAL\nBUILD: Nothing — this is judgement work\nCONFIDENCE: maybe", key: "k", evidence: 1, model: "m")?.confidence, "medium")
        XCTAssertNil(OpportunityAssessor.parse("I think this could be automated somehow.", key: "k", evidence: 1, model: "m"), "no KIND → no judgement")
        XCTAssertNil(OpportunityAssessor.parse(nil, key: "k", evidence: 1, model: "m"))
    }

    func testHeuristicHint() {
        XCTAssertTrue(OpportunityAssessor.looksLikeCustomAppCandidate(units: ["Excel", "Mail", "Excel"], text: "Staff Rota — Week 37.xlsx Re: Availability next week"))
        XCTAssertFalse(OpportunityAssessor.looksLikeCustomAppCandidate(units: ["NetSuite", "Excel", "Preview"], text: "Vendor Bills invoice_10247.pdf"), "real systems, no artefact word")
        XCTAssertFalse(OpportunityAssessor.looksLikeCustomAppCandidate(units: ["Excel", "Notes"], text: "Cash Flow Model.xlsx"), "generic tools but nothing process-shaped")
        XCTAssertFalse(OpportunityAssessor.looksLikeCustomAppCandidate(units: [], text: "rota"))
    }

    func testPromptCarriesEvidenceAndHint() {
        let pattern = WorkflowPattern(apps: ["Excel", "Mail", "Excel"], occurrences: 5, medianDuration: 400, totalDuration: 2000, daysObserved: 3,
                                      automationScore: 40, sampleTitles: [], windows: [], stepLabels: ["Staff Rota — Week 37.xlsx", "Re: Availability next week — Sarah", "Staff Rota — Week 37.xlsx"])
        let insight = WorkflowInsight(pattern: pattern, title: "Staff Rota — Week 37.xlsx", whatItIs: "", whatToAutomate: "", automatable: false,
                                      moments: [SceneNarrative(timestamp: Date(), appName: "Microsoft Excel", windowTitle: "", text: "The user types names into a weekly rota grid.")],
                                      steps: WorkflowInsighter.buildSteps(pattern))
        let p = OpportunityAssessor.prompt(workflow: insight)
        XCTAssertTrue(p.contains("Hint: this looks like a process kept by hand on generic tools"))
        XCTAssertTrue(p.contains("weekly rota grid"))
        XCTAssertTrue(p.contains("KIND: INTEGRATION | APP | STREAMLINE | MANUAL"))
        XCTAssertFalse(p.contains("Sarah") == false, "window titles are evidence; the rules forbid names in the REPLY")
    }

    // MARK: End to end

    private func rotaSpans(days: Int) -> [ActivitySpan] {
        var out: [ActivitySpan] = []
        for d in 0..<days {
            let t0 = base.addingTimeInterval(Double(d) * 86400)
            let items: [(String, String, String, Double)] = [
                ("com.microsoft.Excel", "Microsoft Excel", "Staff Rota — Week 37.xlsx", 240),
                ("com.apple.mail", "Mail", "Re: Availability next week — Sarah", 90),
                ("com.microsoft.Excel", "Microsoft Excel", "Staff Rota — Week 37.xlsx", 150),
                ("com.apple.mail", "Mail", "Re: Availability next week — Tom", 80),
            ]
            var t = t0
            for (b, app, title, dur) in items {
                out.append(ActivitySpan(bundleID: b, appName: app, windowTitle: title, start: t, end: t.addingTimeInterval(dur), keystrokes: 40, clicks: 8, fields: "Name, Mon"))
                t = t.addingTimeInterval(dur + 5)
            }
        }
        return out
    }

    func testAssessorJudgesWorkflowsAndTasksOnceAndReassessesOnMoreEvidence() async {
        let store = Store.inMemory()
        rotaSpans(days: 3).forEach { store.insert($0) }
        let taskID = store.insertTaskSummary(TaskSummary(start: base, end: base.addingTimeInterval(600), title: "Build next week's rota", text: "Laid out shifts and emailed staff for availability.", apps: "Microsoft Excel, Mail", minuteCount: 10, automatable: "Medium — manual scheduling"))
        let reply = "KIND: APP\nBUILD: A rota app: shifts, availability requests and confirmations in one place\nWHY: The rota is a spreadsheet and availability is collected by email.\nDATA: staff, shifts, availability\nCONFIDENCE: high"
        let fake = FakeInterpreter(replies: [reply, reply])
        let assessor = OpportunityAssessor(store: store, interpreter: fake)
        await assessor.run(now: base.addingTimeInterval(4 * 86400))
        XCTAssertEqual(fake.calls, 2, "one call per workflow, one per task")
        let opps = store.opportunities(demo: false)
        XCTAssertEqual(opps.count, 2)
        XCTAssertTrue(opps.keys.contains("task:\(taskID)"))
        XCTAssertEqual(opps.values.map(\.kind), [.customApp, .customApp])
        let wfKey = opps.keys.first { $0.hasPrefix("wf:") }!
        XCTAssertEqual(opps[wfKey]?.evidence, 3)

        // Nothing new: no calls.
        await assessor.run(now: base.addingTimeInterval(4 * 86400))
        XCTAssertEqual(fake.calls, 2)

        // Three more occurrences → the workflow is judged again; the task is not.
        rotaSpans(days: 6).suffix(12).forEach { store.insert($0) }
        fake.replies = ["KIND: APP\nBUILD: A rota app\nWHY: Still by hand.\nDATA: staff\nCONFIDENCE: high"]
        await assessor.run(now: base.addingTimeInterval(7 * 86400))
        XCTAssertEqual(fake.calls, 3)
        XCTAssertEqual(store.opportunity(key: wfKey)?.evidence, 6)
    }

    func testAssessorLeavesNothingBehindWhenOffline() async {
        let store = Store.inMemory()
        rotaSpans(days: 3).forEach { store.insert($0) }
        let fake = FakeInterpreter(replies: [])
        fake.available = false
        let assessor = OpportunityAssessor(store: store, interpreter: fake)
        await assessor.run(now: base.addingTimeInterval(4 * 86400))
        XCTAssertEqual(fake.calls, 0)
        XCTAssertTrue(store.opportunities(demo: false).isEmpty)
    }

    func testStoreRoundTripAndScopes() {
        let store = Store.inMemory()
        store.upsertOpportunity(Opportunity(key: "wf:a", kind: .integration, headline: "H", rationale: "R", entities: ["x", "y"], confidence: "low", model: "m", created: Date(), evidence: 2))
        store.upsertOpportunity(Opportunity(key: "wf:b", kind: .customApp, headline: "H2", rationale: "", entities: [], confidence: "high", model: "demo", created: Date(), evidence: 4, isDemo: true))
        XCTAssertEqual(store.opportunity(key: "wf:a")?.entities, ["x", "y"])
        XCTAssertEqual(store.opportunities(demo: false).count, 1)
        XCTAssertEqual(store.opportunities(demo: true).count, 1)
        store.upsertOpportunity(Opportunity(key: "wf:a", kind: .streamline, headline: "H3", rationale: "R", entities: [], confidence: "medium", model: "m", created: Date(), evidence: 5))
        XCTAssertEqual(store.opportunity(key: "wf:a")?.kind, .streamline, "upsert replaces")
        store.deleteOpportunities(scope: .live)
        XCTAssertNil(store.opportunity(key: "wf:a"))
        XCTAssertNotNil(store.opportunity(key: "wf:b"))
    }

    func testDemoSeedsARotaAppCandidate() {
        let store = Store.inMemory()
        store.insertBatch(DemoData.generate())
        DemoData.seedSummaries(into: store)
        DemoData.seedOpportunities(into: store)
        let opps = store.opportunities(demo: true)
        XCTAssertTrue(opps.values.contains { $0.kind == .customApp && $0.key.hasPrefix("wf:") }, "the demo rota workflow is judged worth an app: \(opps.keys.sorted())")
        XCTAssertTrue(opps.values.contains { $0.kind == .customApp && $0.key.hasPrefix("task:") })
        XCTAssertTrue(opps.values.contains { $0.kind == .integration })
    }
}

extension OpportunityTests {
    /// The model's enthusiasm is held to the evidence.
    func testVerdictIsGuardedByEvidence() {
        typealias A = OpportunityAssessor
        XCTAssertEqual(A.guarded(.integration, mechanical: true, hint: false, cognitive: false), .integration)
        XCTAssertEqual(A.guarded(.integration, mechanical: false, hint: false, cognitive: true), .manual, "documenting with an AI assistant is not an integration")
        XCTAssertEqual(A.guarded(.integration, mechanical: false, hint: false, cognitive: false), .streamline)
        XCTAssertEqual(A.guarded(.customApp, mechanical: false, hint: true, cognitive: false), .customApp, "the hand-run-process shape is enough for APP")
        XCTAssertEqual(A.guarded(.customApp, mechanical: false, hint: true, cognitive: true), .manual, "…but not for judgement work")
        XCTAssertEqual(A.guarded(.customApp, mechanical: false, hint: false, cognitive: true), .manual)
        XCTAssertEqual(A.guarded(.streamline, mechanical: false, hint: false, cognitive: true), .manual)
        XCTAssertEqual(A.guarded(.manual, mechanical: true, hint: true, cognitive: false), .manual, "a MANUAL verdict is never upgraded")

        let low = TaskSummary(start: Date(), end: Date(), title: "t", text: "", apps: "Notes, Excel", minuteCount: 1, automatable: "Low — reading")
        let moved = [ActivitySpan(bundleID: "a", appName: "Notes", windowTitle: "", start: Date(), end: Date(), shortcuts: "⌘C×3"),
                     ActivitySpan(bundleID: "b", appName: "Microsoft Excel", windowTitle: "", start: Date(), end: Date(), shortcuts: "⌘V×3")]
        XCTAssertTrue(A.mechanicalEvidence(task: low, minutes: [], spans: moved), "copies in one app and pastes in another are mechanical evidence even on a Low task")
        let same = [ActivitySpan(bundleID: "b", appName: "Microsoft Excel", windowTitle: "", start: Date(), end: Date(), shortcuts: "⌘C×3, ⌘V×3")]
        XCTAssertFalse(A.mechanicalEvidence(task: low, minutes: [], spans: same), "pasting within one app is not a transfer")
        let none = MinuteSummary(minuteStart: Date(), text: "x", apps: "Claude", keystrokes: 200, clicks: 2, shortcuts: "↵×4", fields: "Message Claude [prompt]", sourceCount: 1)
        XCTAssertFalse(A.mechanicalEvidence(task: low, minutes: [none]))
    }

    func testPromptHasNoLiteralExampleToCopy() {
        let pattern = WorkflowPattern(apps: ["Claude", "Notes"], occurrences: 3, medianDuration: 400, totalDuration: 1200, daysObserved: 1,
                                      automationScore: 30, sampleTitles: [], windows: [], stepLabels: ["Claude", "Feasibility notes"])
        let insight = WorkflowInsight(pattern: pattern, title: "Feasibility notes", whatItIs: "", whatToAutomate: "", automatable: false, moments: [], steps: WorkflowInsighter.buildSteps(pattern))
        let p = OpportunityAssessor.prompt(workflow: insight)
        XCTAssertFalse(p.contains("A rota app:"), "no ready-made headline for the model to parrot")
        XCTAssertTrue(p.contains("MANUAL is the answer unless"))
        XCTAssertFalse(p.contains("Hint:"))
    }
}

extension OpportunityTests {
    func testDowngradeExplainsItself() {
        var o = Opportunity(key: "k", kind: .integration, headline: "Automate the documentation", rationale: "R", entities: [], confidence: "high", model: "m", created: Date(), evidence: 1)
        OpportunityAssessor.apply(guard: .manual, to: &o)
        XCTAssertEqual(o.kind, .manual)
        XCTAssertEqual(o.headline, "Nothing to build \u{2014} this is judgement work")
        XCTAssertTrue(o.rationale.contains("the model suggested automatable"))
        XCTAssertEqual(o.confidence, "low")
        var same = o
        OpportunityAssessor.apply(guard: .manual, to: &same)
        XCTAssertEqual(same, o, "no change when the guard agrees")
    }
}

extension OpportunityTests {
    func testParseToleratesListPrefixesAndRejectsEchoedTemplate() {
        typealias A = OpportunityAssessor
        XCTAssertEqual(A.parse("- KIND: APP\n- BUILD: A tracker", key: "k", evidence: 1, model: "m")?.kind, .customApp)
        XCTAssertEqual(A.parse("1. KIND: STREAMLINE\n2. BUILD: A template", key: "k", evidence: 1, model: "m")?.kind, .streamline)
        XCTAssertEqual(A.parse("KIND \u{2014} MANUAL\nBUILD \u{2014} Nothing", key: "k", evidence: 1, model: "m")?.kind, .manual)
        XCTAssertEqual(A.parse("KIND: Custom app (APP)\nBUILD: x y", key: "k", evidence: 1, model: "m")?.kind, .customApp)
        XCTAssertNil(A.parse("KIND: INTEGRATION | APP | STREAMLINE | MANUAL\nBUILD: <one line>", key: "k", evidence: 1, model: "m"), "an echoed template is not an answer")
        XCTAssertNil(A.parse("KIND: APP or INTEGRATION", key: "k", evidence: 1, model: "m"), "two kinds is no kind")
    }

    /// An unusable reply backs off instead of hogging the budget every tick.
    func testUnusableRepliesBackOff() async {
        let store = Store.inMemory()
        rotaSpans(days: 3).forEach { store.insert($0) }
        let fake = FakeInterpreter(replies: ["garbage", "garbage", "garbage", "garbage"])
        let assessor = OpportunityAssessor(store: store, interpreter: fake)
        let t0 = base.addingTimeInterval(4 * 86400)
        await assessor.run(now: t0)
        let first = fake.calls
        XCTAssertGreaterThan(first, 0)
        await assessor.run(now: t0.addingTimeInterval(90))
        XCTAssertEqual(fake.calls, first, "within the backoff window nothing is re-asked")
        store.insert(ActivitySpan(bundleID: "x", appName: "Notes", windowTitle: "n", start: t0, end: t0.addingTimeInterval(30)))
        await assessor.run(now: t0.addingTimeInterval(11 * 60))
        XCTAssertGreaterThan(fake.calls, first, "after the backoff (10 min) it is asked again")
    }

    func testStaleWorkflowJudgementsArePruned() async {
        let store = Store.inMemory()
        rotaSpans(days: 3).forEach { store.insert($0) }
        store.upsertOpportunity(Opportunity(key: "wf:Ghost>Chain", kind: .integration, headline: "H", rationale: "", entities: [], confidence: "high", model: "m", created: Date(), evidence: 3))
        let fake = FakeInterpreter(replies: ["KIND: MANUAL\nBUILD: Nothing"])
        await OpportunityAssessor(store: store, interpreter: fake).run(now: base.addingTimeInterval(4 * 86400))
        XCTAssertNil(store.opportunity(key: "wf:Ghost>Chain"), "a chain that is no longer mined loses its judgement")
    }

    func testHintNeedsARecordToolAndWholeWords() {
        typealias A = OpportunityAssessor
        XCTAssertTrue(A.looksLikeCustomAppCandidate(units: ["Excel", "Mail"], titles: "Staff Rota \u{2014} Week 37.xlsx", text: ""))
        XCTAssertFalse(A.looksLikeCustomAppCandidate(units: ["Mail", "Calendar"], titles: "Rota", text: ""), "an inbox and a calendar hold no record")
        XCTAssertFalse(A.looksLikeCustomAppCandidate(units: ["Excel", "Notes"], titles: "Cash flow", text: "the user scrolls a long log of entries"), "one free-text hit is not enough")
        XCTAssertTrue(A.looksLikeCustomAppCandidate(units: ["Excel", "Notes"], titles: "Cash flow", text: "a booking list and a rota grid"), "two distinct words in the narrative are")
        XCTAssertFalse(A.looksLikeCustomAppCandidate(units: ["Excel"], titles: "Cash flow", text: "stockholm scheduled"), "substrings don't count: 'stock' in Stockholm, 'schedule' in scheduled")
    }
}
