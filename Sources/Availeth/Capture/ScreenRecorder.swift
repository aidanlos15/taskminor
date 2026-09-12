import AVFoundation
import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

/// A continuous, low-frame-rate recording of the screen — four frames a
/// second, HEVC, written as one-minute segment files — so a task can be
/// replayed rather than described.
///
/// Two layers of gating keep it honest. The stream's content filter is
/// APP-scoped: every window of an excluded app, and of Availeth itself, is cut
/// from the frame whether it was open when the stream started or not, and the
/// filter is rebuilt whenever an excluded app launches. And frames are only
/// WRITTEN while the engine says so (`setWriting`), re-checked on the writer's
/// own 250 ms clock against secure input (a password field) and the frontmost
/// app, so a pause takes effect within a frame, not a polling tick.
///
/// Lifecycle state lives on the main actor; frames, the writer and the timer
/// live on `queue` (also the stream's sample handler queue).
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    static let fps = 4
    static let segmentSeconds: TimeInterval = 60
    /// Output width cap in pixels — 1:1 with points on a MacBook display, so
    /// text stays legible; a larger display is scaled down to this.
    static let maxWidth = 1728
    /// Constant-quality HEVC (0–1): a static screen costs almost nothing and
    /// bits go where the screen changes. Measured on a real frame: ~1.4 MB per
    /// mostly-static minute at 0.7, versus ~7 MB with a 1.5 Mbps bitrate
    /// target, which the encoder fills even when nothing moves.
    static let quality = 0.7
    /// A frame older than this is stale (the stream stopped delivering — display
    /// asleep, lock screen) and is not written again.
    static let maxFrameAge: CFTimeInterval = 2

    static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Availeth/recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// A segment file was closed. Called on the recorder's queue.
    var onSegmentFinished: ((RecordingSegment) -> Void)?

    // Main-thread lifecycle state (the engine drives this on main; the Tasks below hop back to main).
    private var stream: SCStream?
    private var starting = false
    private var wanted = false
    private var generation = 0                       // bumps on every stop/restart; stale starts bail out
    private var exclusions: Set<String> = []
    private var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var launchObserver: NSObjectProtocol?

    // Queue-only state.
    private let queue = DispatchQueue(label: "com.availeth.recorder", qos: .userInitiated)
    private var writing = false
    private var latest: CVPixelBuffer?
    private var latestAt: CFTimeInterval = 0
    private var writer: SegmentWriter?
    private var timer: DispatchSourceTimer?
    private var frameSize = (width: 0, height: 0)
    private var frameDisplay = (id: 0, pointsW: 0, pointsH: 0)   // queue-only
    private var blocked: Set<String> = []            // bundle ids that must never be written
    private var ticks = 0

    // MARK: - Control (main thread)

    /// Runs the stream (idempotent) on `display`, cutting `excludedBundleIDs`
    /// and our own windows from the frame. A different display restarts it.
    /// Main thread only (as is the engine that calls it).
    func start(excludedBundleIDs: Set<String>, display: CGDirectDisplayID) {
        wanted = true
        let blockedNow = excludedBundleIDs.union([Bundle.main.bundleIdentifier ?? ""])
        queue.async { [weak self] in self?.blocked = blockedNow }
        if launchObserver == nil {
            // An excluded app that launches later needs a place in the filter.
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
                guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let b = app.bundleIdentifier, self.exclusions.contains(b) else { return }
                self.restart()
            }
        }
        if excludedBundleIDs != exclusions || display != displayID {
            exclusions = excludedBundleIDs
            displayID = display
            if stream != nil || starting { restart(); return }
        }
        guard stream == nil, !starting else { return }
        launch()
    }

    func stop() {
        wanted = false
        generation &+= 1
        let s = stream
        stream = nil
        queue.async { [weak self] in
            self?.writing = false
            self?.finishSegment()
            self?.stopTimer()
            self?.latest = nil
        }
        if let s { Task { try? await s.stopCapture() } }
    }

    /// Exclusions changed: rebuild the content filter.
    func updateExclusions(_ set: Set<String>) {
        guard set != exclusions else { return }
        exclusions = set
        let blockedNow = set.union([Bundle.main.bundleIdentifier ?? ""])
        queue.async { [weak self] in self?.blocked = blockedNow }
        if wanted { restart() }
    }

    /// Whether frames go to disk right now.
    func setWriting(_ on: Bool) {
        queue.async { [weak self] in
            guard let self, self.writing != on else { return }
            self.writing = on
            if !on { self.finishSegment() }
        }
    }

    /// Closes the segment being written, then calls back on the recorder's
    /// queue once its index is on disk — so a purge or quit never races the
    /// writer.
    func flush(completion: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self, let w = self.writer else { completion(); return }
            self.writer = nil
            self.writing = false
            w.finish { segment in
                if let segment { self.onSegmentFinished?(segment) }
                self.queue.async { completion() }
            }
        }
    }

    /// Synchronous flush for quit.
    func flush(timeout: TimeInterval = 3) {
        let done = DispatchSemaphore(value: 0)
        flush { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    // MARK: - Stream lifecycle (main actor)

    private func restart() {
        generation &+= 1
        let old = stream
        stream = nil
        starting = true                                  // claimed before any await, so start() can't double up
        queue.async { [weak self] in self?.finishSegment(); self?.latest = nil }
        Task { @MainActor [weak self] in
            if let old { try? await old.stopCapture() }
            guard let self else { return }
            if self.wanted { await self.startStream() }
            self.starting = false
        }
    }

    private func launch() {
        starting = true
        Task { @MainActor [weak self] in
            await self?.startStream()
            self?.starting = false
        }
    }

    @MainActor
    private func startStream() async {
        let gen = generation
        guard wanted, Permissions.screenRecordingGranted else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
        guard gen == generation, wanted else { return }
        let display = content.displays.first { $0.displayID == displayID } ?? content.displays.first
        guard let display else { return }
        let selfID = Bundle.main.bundleIdentifier ?? ""
        let apps = content.applications.filter { $0.bundleIdentifier == selfID || exclusions.contains($0.bundleIdentifier) }
        let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
        let scale = min(1.0, Double(Self.maxWidth) / Double(max(1, display.width)))
        let w = Int(Double(display.width) * scale) & ~1, h = Int(Double(display.height) * scale) & ~1

        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.fps))
        config.showsCursor = true
        config.queueDepth = 4
        config.capturesAudio = false

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
        } catch {
            NSLog("Availeth recorder: stream failed to start: \(error.localizedDescription)")
            return
        }
        // Stopped or restarted while we were starting: this stream is stale.
        guard gen == generation, wanted, stream == nil else { try? await s.stopCapture(); return }
        stream = s
        let info = (id: Int(display.displayID), pointsW: display.width, pointsH: display.height)
        queue.async { [weak self] in
            self?.frameSize = (w, h)
            self?.frameDisplay = info
            self?.latest = nil
            self?.startTimer()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latest = pb
        latestAt = CACurrentMediaTime()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Availeth recorder: stream stopped: \(error.localizedDescription)")
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.queue.async { self.finishSegment(); self.stopTimer(); self.latest = nil }
            // Display change, permission flip: try again shortly if still wanted.
            try? await Task.sleep(for: .seconds(5))
            guard self.wanted, self.stream == nil, !self.starting else { return }
            self.launch()
        }
    }

    // MARK: - Writing (queue)

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(Self.fps), leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tickWrite() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    /// Constant-rate writing: every tick appends the newest frame, so a static
    /// screen still yields a playable, correctly timed segment. Re-checks the
    /// things that must stop a recording within a frame: a password field
    /// (secure input) and a blocked app coming to the front.
    private func tickWrite() {
        ticks &+= 1
        guard writing else { return }
        if IsSecureEventInputEnabled() { finishSegment(); return }
        if ticks % 2 == 0, let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, blocked.contains(front) {
            finishSegment(); return
        }
        guard let pb = latest, CACurrentMediaTime() - latestAt <= Self.maxFrameAge else { return }
        if let w = writer, w.elapsed >= Self.segmentSeconds || w.failed { finishSegment() }
        if writer == nil {
            let name = String(format: "seg-%.3f-%@.mov", Date().timeIntervalSince1970, UUID().uuidString.prefix(8) as CVarArg)
                writer = try? SegmentWriter(url: Self.directory().appendingPathComponent(name), width: frameSize.width, height: frameSize.height)
            writer?.display = frameDisplay
        }
        writer?.append(pb)
    }

    private func finishSegment() {
        guard let w = writer else { return }
        writer = nil
        w.finish { [weak self] segment in
            guard let segment else { return }
            self?.queue.async { self?.onSegmentFinished?(segment) }
        }
    }
}

/// One segment file: an AVAssetWriter with HEVC video, timestamps relative to
/// the first appended frame, and the wall-clock instant that frame was taken.
final class SegmentWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var t0: CFTimeInterval?
    private(set) var start: Date?
    private var lastPTS: CMTime?
    private(set) var frames = 0
    private let width: Int, height: Int
    var display = (id: 0, pointsW: 0, pointsH: 0)

    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        self.width = width; self.height = height
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: ScreenRecorder.quality,
                AVVideoExpectedSourceFrameRateKey: ScreenRecorder.fps,
                AVVideoMaxKeyFrameIntervalKey: ScreenRecorder.fps * 4,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw NSError(domain: "Availeth", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot add video input"]) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Availeth", code: 2) }
    }

    /// Seconds since the first frame (0 before any).
    var elapsed: TimeInterval { t0.map { CACurrentMediaTime() - $0 } ?? 0 }
    /// The writer gave up (disk full, say): rotate rather than append no-ops.
    var failed: Bool { writer.status == .failed }

    func append(_ pb: CVPixelBuffer) {
        guard input.isReadyForMoreMediaData, writer.status == .writing else { return }
        if t0 == nil {
            t0 = CACurrentMediaTime()
            start = Date()
            writer.startSession(atSourceTime: .zero)
        }
        let pts = CMTime(seconds: elapsed, preferredTimescale: 600)
        if let last = lastPTS, pts <= last { return }
        if adaptor.append(pb, withPresentationTime: pts) {
            lastPTS = pts
            frames += 1
        }
    }

    /// Closes the file. The segment ends one frame after the last one written.
    /// A file whose index failed to write is removed, not recorded.
    func finish(_ completion: @escaping (RecordingSegment?) -> Void) {
        guard let start, frames > 0, writer.status == .writing else {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            completion(nil)
            return
        }
        let end = start.addingTimeInterval((lastPTS?.seconds ?? 0) + 1.0 / Double(ScreenRecorder.fps))
        input.markAsFinished()
        let display = self.display, width = self.width, height = self.height
        writer.finishWriting { [writer, url] in
            guard writer.status == .completed else {
                NSLog("Availeth recorder: segment failed to finalise: \(writer.error?.localizedDescription ?? "unknown")")
                try? FileManager.default.removeItem(at: url)
                completion(nil)
                return
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            completion(RecordingSegment(start: start, end: end, path: url.path, bytes: bytes, display: display.id,
                                        pointsWidth: display.pointsW, pointsHeight: display.pointsH, pixelsWidth: width, pixelsHeight: height))
        }
    }
}
