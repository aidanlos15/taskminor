import AVFoundation
import XCTest
@testable import Availeth

final class RecordingsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func seg(_ id: Int64, at: TimeInterval, dur: TimeInterval = 60, bytes: Int64 = 1000, keep: Bool = false, path: String = "/tmp/x.mov") -> RecordingSegment {
        RecordingSegment(id: id, start: base.addingTimeInterval(at), end: base.addingTimeInterval(at + dur), path: path, bytes: bytes, keep: keep)
    }

    // MARK: Retention

    func testRetentionPinsOverlapsAndDropsExpired() {
        let now = base.addingTimeInterval(10 * 86400)
        let segments = [
            seg(1, at: 0),                                   // 10 days old, unpinned → delete
            seg(2, at: 3600),                                // 10 days old, overlaps automatable work → pin, keep
            seg(3, at: 9 * 86400),                           // 1 day old → keep
            seg(4, at: -100 * 86400, keep: true),            // pinned but past the pinned hold → delete
        ]
        let pins = [DateInterval(start: base.addingTimeInterval(3600 + 30), end: base.addingTimeInterval(3600 + 40))]
        let plan = Recordings.retentionPlan(segments: segments, pins: pins, now: now)
        XCTAssertEqual(plan.pin, [2])
        XCTAssertEqual(Set(plan.delete), [1, 4])
    }

    func testRetentionCapDropsOldestUnpinnedFirst() {
        let now = base.addingTimeInterval(3600)
        let segments = [
            seg(1, at: 0, bytes: 400, keep: true),
            seg(2, at: 60, bytes: 400),
            seg(3, at: 120, bytes: 400),
            seg(4, at: 180, bytes: 400),
        ]
        let plan = Recordings.retentionPlan(segments: segments, pins: [], now: now, cap: 1000)
        XCTAssertEqual(plan.delete, [2, 3], "oldest unpinned go first; the pinned one survives")
        let tight = Recordings.retentionPlan(segments: segments, pins: [], now: now, cap: 300)
        XCTAssertEqual(tight.delete, [2, 3, 4, 1], "then the pinned one, last")
    }

    // MARK: Cutting

    func testClipPartsCutAcrossSegments() {
        let segments = [seg(1, at: 0), seg(2, at: 60), seg(3, at: 180)]   // a 60 s gap before segment 3
        let parts = Recordings.clipParts(for: DateInterval(start: base.addingTimeInterval(45), end: base.addingTimeInterval(200)), segments: segments)
        XCTAssertEqual(parts.map(\.segment.id), [1, 2, 3])
        XCTAssertEqual(parts[0].offset, 45); XCTAssertEqual(parts[0].duration, 15)
        XCTAssertEqual(parts[1].offset, 0); XCTAssertEqual(parts[1].duration, 60)
        XCTAssertEqual(parts[2].offset, 0); XCTAssertEqual(parts[2].duration, 20)
        XCTAssertTrue(Recordings.clipParts(for: DateInterval(start: base.addingTimeInterval(130), end: base.addingTimeInterval(170)), segments: segments).isEmpty, "the gap has nothing")
    }

    func testWalkthroughWindowsAreThirtySecondsAndKeepOnlyLiveOnes() {
        let occ = DateInterval(start: base.addingTimeInterval(7), end: base.addingTimeInterval(100))
        let moments = [
            SceneNarrative(id: 1, timestamp: base.addingTimeInterval(10), appName: "Notes", windowTitle: "", text: "a"),
            SceneNarrative(id: 2, timestamp: base.addingTimeInterval(20), appName: "Notes", windowTitle: "", text: "b"),
            SceneNarrative(id: 3, timestamp: base.addingTimeInterval(95), appName: "Excel", windowTitle: "", text: "c"),
        ]
        let segments = [seg(1, at: 0, dur: 40)]   // recorded only for the first 40 s
        let wins = Recordings.walkthroughWindows(occurrence: occ, moments: moments, segments: segments)
        XCTAssertEqual(wins.map { $0.interval.start.timeIntervalSince(base) }, [0, 30, 90], "the 60–90 stretch has neither a description nor a recording")
        XCTAssertEqual(wins[0].moments.map(\.id), [1, 2]); XCTAssertTrue(wins[0].recorded)
        XCTAssertTrue(wins[1].moments.isEmpty); XCTAssertTrue(wins[1].recorded)
        XCTAssertEqual(wins[2].moments.map(\.id), [3]); XCTAssertFalse(wins[2].recorded)
    }

    // MARK: Writer + stitching (real HEVC files)

    private func frame(_ w: Int, _ h: Int, shade: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        memset(CVPixelBufferGetBaseAddress(b), Int32(shade), CVPixelBufferGetBytesPerRow(b) * h)
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }

    private func writeSegment(frames: Int, shade: UInt8) async throws -> RecordingSegment {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("availeth-seg-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let w = try SegmentWriter(url: url, width: 320, height: 200)
        let pb = frame(320, 200, shade: shade)
        for _ in 0..<frames {
            w.append(pb)
            try await Task.sleep(for: .milliseconds(1000 / ScreenRecorder.fps))
        }
        return try await withCheckedThrowingContinuation { c in
            w.finish { seg in
                if let seg { c.resume(returning: seg) } else { c.resume(throwing: NSError(domain: "test", code: 1)) }
            }
        }
    }

    func testSegmentWriterProducesPlayableHEVC() async throws {
        let s = try await writeSegment(frames: 8, shade: 120)
        XCTAssertGreaterThan(s.bytes, 0)
        XCTAssertEqual(s.end.timeIntervalSince(s.start), 2.0, accuracy: 0.6, "eight frames at 4 fps")
        let asset = AVURLAsset(url: s.url)
        let dur = try await asset.load(.duration)
        XCTAssertEqual(dur.seconds, 2.0, accuracy: 0.6)
        let track = try await asset.loadTracks(withMediaType: .video).first
        XCTAssertNotNil(track)
        let desc = try await track!.load(.formatDescriptions).first
        XCTAssertEqual(desc.map { CMFormatDescriptionGetMediaSubType($0) }, kCMVideoCodecType_HEVC)
    }

    func testClipStitchesTwoSegmentsWithoutReencoding() async throws {
        let a = try await writeSegment(frames: 8, shade: 40)
        var b = try await writeSegment(frames: 8, shade: 200)
        b.start = a.end.addingTimeInterval(5); b.end = b.start.addingTimeInterval(2)   // a 5 s gap between them
        let interval = DateInterval(start: a.start.addingTimeInterval(1), end: b.end)
        let parts = Recordings.clipParts(for: interval, segments: [a, b])
        XCTAssertEqual(parts.count, 2)
        let built = await Recordings.clip(parts)
        let clip = try XCTUnwrap(built)
        XCTAssertEqual(clip.duration.seconds, 3.0, accuracy: 0.6, "1 s of the first, 2 s of the second, gap removed")
        // Wall-clock → composition time skips the gap.
        XCTAssertEqual(clip.time(for: b.start.addingTimeInterval(1))?.seconds ?? -1, 2.0, accuracy: 0.6)
        XCTAssertNil(clip.time(for: a.end.addingTimeInterval(2)), "inside the gap → not recorded")
        XCTAssertEqual(clip.nearestTime(for: a.end.addingTimeInterval(2))?.seconds ?? -1, 1.0, accuracy: 0.6, "seeking lands on the next piece")
        let poster = await Recordings.poster(for: parts[1])
        XCTAssertNotNil(poster)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("availeth-stitched-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        var last = 0.0
        try await Recordings.export(clip, to: out) { last = $0 }
        XCTAssertEqual(last, 1)
        let exported = try await AVURLAsset(url: out).load(.duration)
        XCTAssertEqual(exported.seconds, 3.0, accuracy: 0.6)
    }

    // MARK: Store

    func testRecordingStoreRoundTrip() {
        let store = Store.inMemory()
        let id1 = store.insertRecording(seg(0, at: 0, path: "/tmp/a.mov"))
        let id2 = store.insertRecording(seg(0, at: 60, path: "/tmp/b.mov"))
        XCTAssertEqual(store.recordings(from: base.addingTimeInterval(30), to: base.addingTimeInterval(70)).map(\.id), [id1, id2])
        XCTAssertEqual(store.recordings(from: base.addingTimeInterval(61), to: base.addingTimeInterval(70)).map(\.id), [id2])
        store.markRecordingsKept(ids: [id2])
        XCTAssertEqual(store.allRecordings().map(\.keep), [false, true])
        XCTAssertEqual(store.recordingStats().count, 2)
        XCTAssertEqual(store.deleteRecordings(ids: [id1]), ["/tmp/a.mov"])
        XCTAssertEqual(store.deleteAllRecordings(), ["/tmp/b.mov"])
        XCTAssertEqual(store.recordingStats().count, 0)
    }

    // MARK: Export

    func testExportFolderNamingAndSafeNames() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("availeth-export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 12))!
        let first = ExportJob.folderURL(in: tmp, date: date)
        XCTAssertEqual(first.lastPathComponent, "Availeth Data 2026-09-12")
        try? FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        XCTAssertEqual(ExportJob.folderURL(in: tmp, date: date).lastPathComponent, "Availeth Data 2026-09-12 (2)")
        XCTAssertEqual(ExportJob.safeName("Vendor Bills / NetSuite: Q3?"), "Vendor Bills - NetSuite- Q3-")
        XCTAssertEqual(ExportJob.safeName("   "), "Untitled")
    }

    func testExportWritesOnlyAutomatableWork() async throws {
        let store = Store.inMemory()
        let now = Date()
        store.insertTaskSummary(TaskSummary(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-3000), title: "Enter supplier invoices",
                                            text: "Copied totals.", apps: "Notes, Excel", minuteCount: 10, automatable: "High \u{2014} copy/paste between systems"))
        store.insertTaskSummary(TaskSummary(start: now.addingTimeInterval(-2000), end: now.addingTimeInterval(-1500), title: "Read the news",
                                            text: "Browsing.", apps: "Chrome", minuteCount: 8, automatable: "Low \u{2014} reading"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("availeth-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        var job = ExportJob(store: store, hourlyRate: 45)
        job.desktop = tmp
        var seen: [Double] = []
        let folder = try await job.run { p, _ in seen.append(p) }
        let tasks = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Tasks").path)
        XCTAssertEqual(tasks, ["01 - Enter supplier invoices"], "the Low task is not exported")
        let readme = try String(contentsOf: folder.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("ONLY the work Availeth judged automatable"))
        XCTAssertTrue(readme.contains("Enter supplier invoices"))
        XCTAssertFalse(readme.contains("Read the news"))
        XCTAssertEqual(seen.last, 1)
        XCTAssertEqual(seen, seen.sorted(), "progress never goes backwards")
    }
}

extension RecordingsTests {
    func testSweepOrphansRemovesUnindexedFilesAndDeadRows() throws {
        let store = Store.inMemory()
        // A private directory: the sweep must never be pointed at the real one from a test.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("availeth-recordings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let orphan = dir.appendingPathComponent("seg-orphan.mov")
        let live = dir.appendingPathComponent("seg-live.mov")
        try Data([0, 1, 2]).write(to: orphan)
        try Data([0, 1, 2]).write(to: live)
        let now = Date()
        store.insertRecording(RecordingSegment(start: now, end: now.addingTimeInterval(60), path: live.path, bytes: 3))
        let dead = store.insertRecording(RecordingSegment(start: now, end: now.addingTimeInterval(60), path: dir.appendingPathComponent("gone.mov").path, bytes: 3))
        Recordings.sweepOrphans(store: store, directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "the unindexed file is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "the indexed file stays")
        XCTAssertEqual(store.allRecordings().map(\.id).contains(dead), false, "the row with no file is removed")
        XCTAssertEqual(store.allRecordings().count, 1)
    }
}

extension RecordingsTests {
    /// Nothing is deleted while a player or export is reading; the pass runs
    /// again ten minutes later.
    func testRetentionSkipsDeletionWhileBeingRead() {
        let store = Store.inMemory()
        let old = Date().addingTimeInterval(-30 * 86400)
        store.insertRecording(RecordingSegment(start: old, end: old.addingTimeInterval(60), path: "/tmp/none.mov", bytes: 1))
        Recordings.beginReading()
        defer { Recordings.endReading() }
        // sweepOrphans would drop the row (file missing) — point it at an empty dir.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("availeth-rt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        Recordings.sweepOrphans(store: store, directory: dir)
        XCTAssertEqual(store.allRecordings().count, 0, "a row whose file is gone is dropped by the sweep regardless")
    }

    func testWalkthroughWindowsCarryTheirFirstPart() {
        let occ = DateInterval(start: base, end: base.addingTimeInterval(60))
        let segments = [seg(1, at: -30, dur: 60), seg(2, at: 30, dur: 60)]
        let wins = Recordings.walkthroughWindows(occurrence: occ, moments: [], segments: segments)
        XCTAssertEqual(wins.count, 2)
        XCTAssertEqual(wins[0].part?.segment.id, 1); XCTAssertEqual(wins[0].part?.offset, 30)
        XCTAssertEqual(wins[1].part?.segment.id, 2); XCTAssertEqual(wins[1].part?.offset, 0)
    }
}
