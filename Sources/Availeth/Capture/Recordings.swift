import AVFoundation
import AppKit

/// What to keep, what to play: retention of recording segments, cutting a
/// wall-clock interval out of them, and stitching the pieces into one
/// playable composition (no re-encoding).
enum Recordings {
    /// Unpinned segments are deleted after this.
    static let hold: TimeInterval = 7 * 86400
    /// Segments pinned to automatable work are kept this long.
    static let pinnedHold: TimeInterval = 90 * 86400
    /// Total on-disk budget; the oldest unpinned segments go first. A working
    /// day is ~0.7–1 GB at constant quality, so a week fits.
    static let diskCap: Int64 = 8 * 1024 * 1024 * 1024

    // MARK: - Retention

    struct RetentionPlan: Equatable {
        var pin: [Int64]       // newly pinned (overlaps automatable work)
        var delete: [Int64]
    }

    /// Pure: which segments to pin and which to delete, given the intervals of
    /// automatable work. A segment is pinned once it overlaps such an interval;
    /// pinned segments outlive the hold window (up to `pinnedHold`); the disk
    /// cap trims the oldest unpinned first, then the oldest pinned.
    static func retentionPlan(segments: [RecordingSegment], pins: [DateInterval], now: Date,
                              hold: TimeInterval = hold, pinnedHold: TimeInterval = pinnedHold, cap: Int64 = diskCap) -> RetentionPlan {
        var pin: [Int64] = [], delete: [Int64] = []
        var kept: [(seg: RecordingSegment, pinned: Bool)] = []
        for s in segments {
            let pinned = s.keep || pins.contains { $0.intersects(s.interval) }
            if pinned, !s.keep { pin.append(s.id) }
            let age = now.timeIntervalSince(s.end)
            if age > (pinned ? pinnedHold : hold) { delete.append(s.id); continue }
            kept.append((s, pinned))
        }
        var bytes = kept.reduce(Int64(0)) { $0 + $1.seg.bytes }
        if bytes > cap {
            let order = kept.sorted { a, b in
                if a.pinned != b.pinned { return !a.pinned }     // unpinned first
                return a.seg.start < b.seg.start                  // then oldest
            }
            for item in order where bytes > cap {
                delete.append(item.seg.id)
                bytes -= item.seg.bytes
            }
        }
        return RetentionPlan(pin: pin, delete: delete)
    }

    /// The intervals of work worth keeping video for: occurrences of
    /// automatable workflows and High/Medium tasks in the last two weeks.
    static func automatableIntervals(store: Store, now: Date = Date()) -> [DateInterval] {
        let from = now.addingTimeInterval(-14 * 86400), to = now.addingTimeInterval(60)
        var out: [DateInterval] = []
        for t in store.taskSummaries(from: from, to: to, demo: false)
            where t.automatable.hasPrefix("High") || t.automatable.hasPrefix("Medium") {
            out.append(DateInterval(start: t.start.addingTimeInterval(-60), end: t.end.addingTimeInterval(60)))
        }
        let spans = store.spans(from: from, to: to, demo: false)
        for p in PatternMiner.mine(spans: spans) {
            let insight = WorkflowInsighter.build(p, store: store, demo: false)
            guard insight.automatable else { continue }
            for w in p.windows { out.append(DateInterval(start: w.start.addingTimeInterval(-120), end: w.end.addingTimeInterval(120))) }
        }
        return out
    }

    /// Open players and running exports: while any are reading, nothing is
    /// deleted (a pass ten minutes later will).
    private static let readersLock = NSLock()
    private static var readers = 0
    static func beginReading() { readersLock.lock(); readers += 1; readersLock.unlock() }
    static func endReading() { readersLock.lock(); readers = max(0, readers - 1); readersLock.unlock() }
    static var isBeingRead: Bool { readersLock.lock(); defer { readersLock.unlock() }; return readers > 0 }

    /// Runs one retention pass: pins, deletes rows, removes files. Off-main.
    /// Returns the plan so the caller can tell views something changed.
    @discardableResult
    static func retentionPass(store: Store, now: Date = Date()) -> RetentionPlan {
        sweepOrphans(store: store)
        var plan = retentionPlan(segments: store.allRecordings(), pins: automatableIntervals(store: store, now: now), now: now)
        store.markRecordingsKept(ids: plan.pin)
        if isBeingRead { plan.delete = [] } else { ScreenshotCapture.deleteFiles(store.deleteRecordings(ids: plan.delete)) }
        return plan
    }

    /// Removes segment files no row refers to (a segment being written when the
    /// app died has no index and can't play) and rows whose file is gone.
    /// `directory` is only ever the app's own recordings folder; tests pass a
    /// temporary one — never the real one with a throwaway store.
    static func sweepOrphans(store: Store, directory dir: URL = ScreenRecorder.directory()) {
        let rows = store.allRecordings()
        let referenced = Set(rows.map(\.path))
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for f in files where f.hasSuffix(".mov") {
                let p = dir.appendingPathComponent(f).path
                if !referenced.contains(p) { try? FileManager.default.removeItem(atPath: p) }
            }
        }
        let missing = rows.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.id)
        store.deleteRecordings(ids: missing)
    }

    /// Deletes every recording (rows and files).
    static func purgeAll(store: Store) {
        ScreenshotCapture.deleteFiles(store.deleteAllRecordings())
        try? FileManager.default.removeItem(at: ScreenRecorder.directory())
    }

    // MARK: - Cutting

    /// A piece of one segment file: `offset` seconds in, for `duration`.
    struct ClipPart: Hashable {
        var segment: RecordingSegment
        var offset: TimeInterval
        var duration: TimeInterval
        var start: Date { segment.start.addingTimeInterval(offset) }
    }

    /// The pieces of the segments that fall inside `interval`, in order. Gaps
    /// (paused recording) simply aren't there.
    static func clipParts(for interval: DateInterval, segments: [RecordingSegment]) -> [ClipPart] {
        segments.sorted { $0.start < $1.start }.compactMap { s in
            let a = max(s.start, interval.start), b = min(s.end, interval.end)
            let d = b.timeIntervalSince(a)
            guard d >= 0.25 else { return nil }
            return ClipPart(segment: s, offset: a.timeIntervalSince(s.start), duration: d)
        }
    }

    static func hasRecording(for interval: DateInterval, segments: [RecordingSegment]) -> Bool {
        !clipParts(for: interval, segments: segments).isEmpty
    }

    // MARK: - Stitching

    /// A playable composition plus the map from wall-clock to composition time.
    final class Clip {
        let composition: AVMutableComposition
        let parts: [(part: ClipPart, at: CMTime)]
        let duration: CMTime
        init(composition: AVMutableComposition, parts: [(ClipPart, CMTime)], duration: CMTime) {
            self.composition = composition; self.parts = parts.map { ($0.0, $0.1) }; self.duration = duration
        }
        /// Where a moment sits in the stitched video — nil when that instant
        /// was not recorded (a gap, or outside the clip).
        func time(for date: Date) -> CMTime? {
            for (p, at) in parts where date >= p.start && date <= p.start.addingTimeInterval(p.duration) {
                return at + CMTime(seconds: date.timeIntervalSince(p.start), preferredTimescale: 600)
            }
            return nil
        }

        /// For seeking: the moment itself, or the start of the next recorded piece.
        func nearestTime(for date: Date) -> CMTime? {
            time(for: date) ?? parts.first { $0.part.start > date }?.at
        }
    }

    /// Stitches the parts into one composition, no re-encoding. Off-main.
    static func clip(_ parts: [ClipPart]) async -> Clip? {
        guard !parts.isEmpty else { return nil }
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var cursor = CMTime.zero
        var placed: [(ClipPart, CMTime)] = []
        var size: CGSize?
        for p in parts {
            let asset = AVURLAsset(url: p.segment.url)
            guard let src = try? await asset.loadTracks(withMediaType: .video).first,
                  let total = try? await asset.load(.duration) else { continue }
            // One track, one frame size: a segment from a different display
            // (a monitor plugged in mid-run) would play squashed, so it is left out.
            if let natural = try? await src.load(.naturalSize) {
                if let size, size != natural { continue }
                size = natural
            }
            let available = total.seconds - p.offset
            guard available > 0.2 else { continue }
            let range = CMTimeRange(start: CMTime(seconds: p.offset, preferredTimescale: 600),
                                    duration: CMTime(seconds: min(p.duration, available), preferredTimescale: 600))
            do {
                try track.insertTimeRange(range, of: src, at: cursor)
            } catch { continue }
            var inserted = p
            inserted.duration = range.duration.seconds   // what actually went in, not what was asked for
            placed.append((inserted, cursor))
            cursor = cursor + range.duration
        }
        guard !placed.isEmpty else { return nil }
        return Clip(composition: comp, parts: placed, duration: cursor)
    }

    /// One frame from a segment, for a row's poster. Off-main.
    static func poster(for part: ClipPart, maxWidth: CGFloat = 480) async -> NSImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: part.segment.url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        guard let (cg, _) = try? await gen.image(at: CMTime(seconds: part.offset, preferredTimescale: 600)) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Writes the stitched clip to a .mov (passthrough — the encoded frames are
    /// copied, not re-encoded). `progress` is awaited in order, 0…1.
    static func export(_ clip: Clip, to url: URL, progress: @escaping (Double) async -> Void) async throws {
        guard let session = AVAssetExportSession(asset: clip.composition, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "Availeth", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create the export session."])
        }
        try? FileManager.default.removeItem(at: url)
        session.outputURL = url
        session.outputFileType = .mov
        let exporting = Task { await session.export() }
        while !exporting.isCancelled {
            if session.status == .completed || session.status == .failed || session.status == .cancelled { break }
            await progress(min(0.99, Double(session.progress)))
            try? await Task.sleep(for: .milliseconds(200))
        }
        await exporting.value
        if let e = session.error { throw e }
        await progress(1)
    }

    // MARK: - Walkthrough windows

    /// One 30-second stretch of a run: the clip to play and every description
    /// the model wrote in that time.
    struct Window: Identifiable, Equatable {
        var id: Int
        var interval: DateInterval
        var moments: [SceneNarrative]
        var recorded: Bool { part != nil }
        /// The first recorded piece of this stretch — its poster and play target.
        var part: ClipPart?
    }

    /// Splits an occurrence (widened to cover its attached moments) into
    /// `step`-second windows, keeping those with a description or a recording.
    static func walkthroughWindows(occurrence: DateInterval, moments: [SceneNarrative], segments: [RecordingSegment], step: TimeInterval = 30) -> [Window] {
        var start = occurrence.start, end = occurrence.end
        for m in moments { start = min(start, m.timestamp); end = max(end, m.timestamp.addingTimeInterval(1)) }
        start = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970 / step) * step)
        let sorted = segments.sorted { $0.start < $1.start }
        var out: [Window] = []
        var t = start, i = 0
        while t < end && i < 400 {
            let iv = DateInterval(start: t, end: t.addingTimeInterval(step))
            let ms = moments.filter { $0.timestamp >= iv.start && $0.timestamp < iv.end }
            let part = clipParts(for: iv, segments: sorted).first
            if !ms.isEmpty || part != nil { out.append(Window(id: i, interval: iv, moments: ms, part: part)) }
            t = iv.end; i += 1
        }
        return out
    }
}

extension DateInterval {
    /// A little slack either side, so a run's first and last seconds are in.
    var padded: DateInterval { DateInterval(start: start.addingTimeInterval(-15), end: end.addingTimeInterval(15)) }
}
