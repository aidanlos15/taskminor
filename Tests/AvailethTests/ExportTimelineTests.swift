import XCTest
@testable import Availeth

final class ExportTimelineTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testEventsMergeAndOrderWithClipOffsets() {
        let iv = DateInterval(start: base, end: base.addingTimeInterval(120))
        let spans = [
            ActivitySpan(bundleID: "a", appName: "Notes", windowTitle: "Invoices to enter", start: base.addingTimeInterval(-10), end: base.addingTimeInterval(20), shortcuts: "⌘C×3"),
            ActivitySpan(bundleID: "b", appName: "Microsoft Excel", windowTitle: "Supplier Invoices.xlsx", start: base.addingTimeInterval(21), end: base.addingTimeInterval(60), fields: "Amount"),
        ]
        let narr = [SceneNarrative(id: 1, timestamp: base.addingTimeInterval(30), appName: "Microsoft Excel", windowTitle: "", text: "Pasting a total. More.")]
        let inputs = [
            InputEvent(timestamp: base.addingTimeInterval(5), kind: .copy, appName: "Notes", bundleID: "a"),
            InputEvent(timestamp: base.addingTimeInterval(25), kind: .paste, appName: "Microsoft Excel", bundleID: "b", label: "Amount"),
            InputEvent(timestamp: base.addingTimeInterval(26), kind: .click, appName: "Microsoft Excel", bundleID: "b", x: 400, y: 300, display: 1),
            InputEvent(timestamp: base.addingTimeInterval(200), kind: .save, appName: "Microsoft Excel", bundleID: "b"),   // outside
        ]
        let events = ExportTimeline.events(interval: iv, spans: spans, narratives: narr, minutes: [], inputEvents: inputs, idles: [], clip: nil)
        XCTAssertEqual(events.map(\.kind), ["focus", "copy", "focus", "paste", "click", "scene"])
        XCTAssertEqual(events[0].t, 0, "a span that started before the interval is clamped to it")
        XCTAssertEqual(events[0].duration, 20)
        XCTAssertEqual(events[3].label, "Amount")
        XCTAssertEqual(events[4].x, 400)
        let jsonl = ExportTimeline.jsonl(events)
        XCTAssertEqual(jsonl.split(separator: "\n").count, 6)
        XCTAssertTrue(jsonl.contains("\"kind\":\"paste\""))
        XCTAssertTrue(jsonl.contains("\"display\":1"))
    }

    func testStoryboardScoresNoveltyAndRepeats() {
        let iv = DateInterval(start: base, end: base.addingTimeInterval(120))
        func focus(_ at: TimeInterval, _ app: String, _ title: String) -> ExportTimeline.Event {
            ExportTimeline.Event(t: at, timestamp: base.addingTimeInterval(at), kind: "focus", app: app, title: title, duration: 10)
        }
        func ev(_ at: TimeInterval, _ kind: String) -> ExportTimeline.Event {
            ExportTimeline.Event(t: at, timestamp: base.addingTimeInterval(at), kind: kind, app: "Excel")
        }
        let events = [
            focus(2, "Notes", "List"), ev(5, "copy"), focus(10, "Excel", "Sheet"), ev(12, "paste"),   // window 1: new + data moved
            focus(35, "Notes", "List"), focus(45, "Excel", "Sheet"),                                    // window 2: same windows, nothing moved
            focus(65, "Notes", "List"), ev(70, "copy"), focus(75, "Excel", "Sheet"), ev(80, "paste"),  // window 3: repeat, but data moved
            ev(100, "away"),                                                                           // window 4: away
        ]
        let board = ExportTimeline.storyboard(interval: iv, events: events)
        XCTAssertEqual(board.count, 4)
        XCTAssertEqual(board[0].suggestion, "1\u{00D7}")
        XCTAssertGreaterThanOrEqual(board[0].score, 8)
        XCTAssertEqual(board[1].repeats, 1, "same windows as stretch 1 with nothing moved")
        XCTAssertEqual(board[1].suggestion, "5\u{00D7} fast-forward")
        XCTAssertNil(board[2].repeats, "data moved, so it is not a mere repeat")
        XCTAssertEqual(board[2].suggestion, "1\u{00D7}")
        XCTAssertLessThan(board[3].score, 0)
        let md = ExportTimeline.storyboardMarkdown(title: "T", clip: "run-01.mov", windows: board)
        XCTAssertTrue(md.contains("| 2 |") && md.contains("repeats #1"))
    }

    func testExportWritesManifestEventsAndStoryboards() async throws {
        let store = Store.inMemory()
        let now = Date()
        let id = store.insertTaskSummary(TaskSummary(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-3000), title: "Enter supplier invoices",
                                                     text: "Copied totals.", apps: "Notes, Excel", minuteCount: 10, automatable: "High \u{2014} copy/paste"))
        store.upsertOpportunity(Opportunity(key: "task:\(id)", kind: .integration, headline: "Post bills automatically", rationale: "All systems hold the data.", entities: ["invoices"], confidence: "high", model: "m", created: now, evidence: 10))
        store.insertInputEvents([InputEvent(timestamp: now.addingTimeInterval(-3500), kind: .paste, appName: "Microsoft Excel", bundleID: "b", label: "Amount")])
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("availeth-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        var job = ExportJob(store: store, hourlyRate: 45)
        job.desktop = tmp
        let folder = try await job.run { _, _ in }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as! [String: Any]
        let tasks = manifest["tasks"] as! [[String: Any]]
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0]["kind"] as? String, "integration")
        let taskDir = folder.appendingPathComponent(tasks[0]["folder"] as! String)
        let events = try String(contentsOf: taskDir.appendingPathComponent("events.jsonl"), encoding: .utf8)
        XCTAssertTrue(events.contains("\"kind\":\"paste\"") && events.contains("\"label\":\"Amount\""))
        let board = try String(contentsOf: taskDir.appendingPathComponent("storyboard.md"), encoding: .utf8)
        XCTAssertTrue(board.hasPrefix("# Storyboard"))
        let readme = try String(contentsOf: taskDir.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("Post bills automatically"))
        let top = try String(contentsOf: folder.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(top.contains("events.jsonl"))
    }

    func testInputEventStoreRoundTripAndPrune() {
        let store = Store.inMemory()
        let now = Date()
        store.insertInputEvents([
            InputEvent(timestamp: now.addingTimeInterval(-100 * 86400), kind: .click, appName: "Old", bundleID: "o", x: 1, y: 2, display: 3),
            InputEvent(timestamp: now.addingTimeInterval(-10), kind: .typing, appName: "Notes", bundleID: "n", label: "Body", count: 42),
        ])
        XCTAssertEqual(store.inputEventCount(demo: false), 2)
        let recent = store.inputEvents(from: now.addingTimeInterval(-60), to: now, demo: false)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].count, 42); XCTAssertNil(recent[0].x)
        store.pruneInputEvents(olderThan: now.addingTimeInterval(-90 * 86400))
        XCTAssertEqual(store.inputEventCount(demo: false), 1)
        store.deleteInputEvents(scope: .live)
        XCTAssertEqual(store.inputEventCount(demo: false), 0)
    }
}

extension ExportTimelineTests {
    func testStoryboardWindowsUseTheClipTimeMap() {
        let iv = DateInterval(start: base, end: base.addingTimeInterval(90))
        // Recorded only from 40 s on: the first window is unrecorded, the rest map.
        let map: (Date) -> Double? = { d in let s = d.timeIntervalSince(self.base); return s >= 40 ? s - 40 : nil }
        let board = ExportTimeline.storyboard(interval: iv, events: [], time: map)
        XCTAssertEqual(board.count, 3)
        XCTAssertNil(board[0].t)
        XCTAssertEqual(board[1].t, nil, "window 2 starts at 30 s, before the recording")
        XCTAssertEqual(board[1].tEnd, 20)
        XCTAssertEqual(board[2].t, 20); XCTAssertEqual(board[2].tEnd, 50)
    }

    func testAltTabChurnDoesNotScoreAsNovelty() {
        let iv = DateInterval(start: base, end: base.addingTimeInterval(60))
        func focus(_ at: TimeInterval, _ app: String) -> ExportTimeline.Event {
            ExportTimeline.Event(t: at, timestamp: base.addingTimeInterval(at), kind: "focus", app: app, title: "X", duration: 2)
        }
        let churn = (0..<24).map { focus(Double($0) * 2.4, $0 % 2 == 0 ? "A" : "B") }   // 0–55 s, both windows
        let board = ExportTimeline.storyboard(interval: iv, events: churn)
        XCTAssertEqual(board[0].score, 6, "two new windows: 3 + 3, however often they alternate")
        XCTAssertEqual(board[1].repeats, 1)
    }

    func testEventsMarkUnrecordedInstants() async throws {
        // A clip covering only [base+10, base+20): an event at base+5 has no t.
        let a = try await writeTinySegment(start: base.addingTimeInterval(10), seconds: 10)
        let parts = Recordings.clipParts(for: DateInterval(start: base, end: base.addingTimeInterval(30)), segments: [a])
        let built = await Recordings.clip(parts)
        let clip = try XCTUnwrap(built)
        let inputs = [InputEvent(timestamp: base.addingTimeInterval(5), kind: .click, appName: "A", bundleID: "a", x: 1, y: 1),
                      InputEvent(timestamp: base.addingTimeInterval(15), kind: .paste, appName: "A", bundleID: "a")]
        let events = ExportTimeline.events(interval: DateInterval(start: base, end: base.addingTimeInterval(30)), spans: [], narratives: [], minutes: [], inputEvents: inputs, idles: [], clip: clip)
        XCTAssertNil(events[0].t); XCTAssertFalse(events[0].recorded)
        XCTAssertEqual(events[1].t ?? -1, 5, accuracy: 0.6); XCTAssertTrue(events[1].recorded)
        XCTAssertTrue(ExportTimeline.jsonl(events).contains("\"recorded\":false"))
    }

    private func writeTinySegment(start: Date, seconds: Int) async throws -> RecordingSegment {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("availeth-tl-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let w = try SegmentWriter(url: url, width: 64, height: 64)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        for _ in 0..<(seconds * ScreenRecorder.fps) { w.append(pb!); try await Task.sleep(for: .milliseconds(1000 / ScreenRecorder.fps)) }
        var seg: RecordingSegment = try await withCheckedThrowingContinuation { c in
            w.finish { s in if let s { c.resume(returning: s) } else { c.resume(throwing: NSError(domain: "t", code: 1)) } }
        }
        seg.start = start; seg.end = start.addingTimeInterval(Double(seconds))
        return seg
    }
}
