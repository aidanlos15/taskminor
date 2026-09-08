import AppKit
import Combine
import CoreGraphics

/// Observes the user's foreground activity and writes ActivitySpans to the store.
///
/// Signals used — all local, none requiring Screen Recording or Input Monitoring:
///  - NSWorkspace app-activation notifications (no permission needed)
///  - focused-window title via Accessibility, if the user granted it
///  - system idle time via CGEventSource (a query, not an event tap)
///
/// Policy enforcement happens here, locally: excluded apps produce no data at all.
/// Pause/stop choices persist across launches — capture never silently restarts
/// after the user turned it off.
final class CaptureEngine: ObservableObject {

    @Published private(set) var isObserving = false
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var currentAppName: String?
    @Published private(set) var observedTodaySeconds: TimeInterval = 0

    /// Bundle IDs never observed. Persisted in UserDefaults.
    @Published var excludedBundleIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(excludedBundleIDs), forKey: Self.exclusionsKey) }
    }

    /// Nothing is excluded by default — Availeth records everything unless the
    /// user explicitly excludes an app in the Privacy tab.
    static let defaultExclusions: Set<String> = []

    /// The set Availeth used to auto-exclude (password managers, messengers,
    /// System Settings). Retained only so the version-3 migration can strip them
    /// from existing installs; user-added exclusions outside this set are kept.
    private static let legacyDefaultExclusions: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "org.keepassxc.keepassxc", "com.dashlane.dashlanephonefinal", "com.lastpass.lastpassmacdesktop",
        "in.sinew.Enpass-Desktop", "com.apple.Passwords", "com.apple.keychainaccess",
        "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "org.whispersystems.signal-desktop",
        "ru.keepcoder.Telegram", "com.tdesktop.Telegram", "com.hnc.Discord",
        "com.apple.systempreferences",
    ]
    private static let exclusionsKey = "availeth.exclusions"
    private static let exclusionsVersionKey = "availeth.exclusionsVersion"
    private static let exclusionsVersion = 3
    private static let observingEnabledKey = "availeth.observingEnabled"
    private static let pausedUntilKey = "availeth.pausedUntil"

    var onSpanSaved: (() -> Void)?

    // MARK: - Opt-in enrichment capabilities (each default OFF, permission-gated)

    /// Interaction Telemetry mode (off / standard / deep) — structure only,
    /// never typed content.
    @Published var telemetryMode: InputTelemetryMode {
        didSet {
            UserDefaults.standard.set(telemetryMode.rawValue, forKey: "availeth.cap.telemetry")
            syncInputMonitor()
        }
    }
    /// Screen-capture behavior: off / redacted thumbnails / local storyline.
    @Published var screenshotMode: ScreenshotMode {
        didSet {
            UserDefaults.standard.set(screenshotMode.rawValue, forKey: "availeth.cap.screenshotMode")
            // Changing mode invalidates any queued/in-flight storyline work, so it
            // can't narrate now-stale frames (with old timestamps) after a round-trip.
            captureEpoch &+= 1
            pendingFrames.removeAll()
            if screenshotMode == .storyline { refreshInterpreterStatus() }
        }
    }
    /// How much the vision model reports per frame (activity vs detailed).
    @Published var captureDepth: CaptureDepth {
        didSet { UserDefaults.standard.set(captureDepth.rawValue, forKey: "availeth.cap.depth") }
    }
    /// Whether the local vision model (Ollama) is reachable for storyline mode.
    @Published private(set) var interpreterReady = false
    /// Record which document is open (identity/path only, never contents).
    @Published var fileTrackingEnabled: Bool {
        didSet { UserDefaults.standard.set(fileTrackingEnabled, forKey: "availeth.cap.files") }
    }

    /// How long redacted screenshots are kept before automatic deletion.
    var screenshotRetention: TimeInterval = 24 * 3600
    /// Never capture more often than this, even when the context changes. Short
    /// for storyline (frame grab is cheap and queued) so fast app-switches in a
    /// workflow — e.g. Notes ⇄ a browser tab — are all captured.
    private func captureFloor() -> TimeInterval { screenshotMode == .storyline ? 3 : 8 }
    /// Safety-net interval: capture at least this often on a static-but-active
    /// screen. Shorter for storyline so a single-window conversation (e.g. a
    /// Claude/ChatGPT thread, where the title never changes) is sampled often
    /// enough to catch both the prompt and the answer.
    private func captureInterval() -> TimeInterval { screenshotMode == .storyline ? 25 : 120 }
    private var lastScreenshotDate = Date.distantPast
    /// bundleID|normalized-title of the last captured frame, for change detection.
    private var lastCaptureContext = ""
    private var lastInterpreterCheck = Date.distantPast
    private var pendingActionCapture: DispatchWorkItem?
    private var pendingActionReason = ""
    private var pendingActionBundleID = ""

    /// When the current away-from-keyboard stretch began, or nil if active.
    private var idleSince: Date?
    /// Last moment the user was known present — the floor for a new idle start,
    /// so idle stretches can never overlap a prior one or precede launch.
    private var lastPresentAt = Date()
    /// Minimum away time worth recording as an idle session.
    private let minIdleToRecord: TimeInterval = 60

    var onIdleRecorded: (() -> Void)?

    private let inputMonitor = InputMonitor()
    private let screenshotCapture = ScreenshotCapture()
    private let interpreter: SceneInterpreter = OllamaInterpreter()
    private var captureInFlight = false
    /// Identifies each capture; a late/abandoned op with a stale generation may
    /// neither store its result nor clear captureInFlight.
    private var captureGeneration = 0
    /// Bumped whenever the storyline capture context is invalidated (stop, suspend,
    /// pause, or a mode change). A grab or narration that started under an older
    /// epoch must not enqueue or store — this is what the thumbnail path gets from
    /// the generation token, which storyline can't reuse (it bumps per grab).
    private var captureEpoch = 0
    /// Wall-clock ceiling after which captureInFlight is force-freed even if the
    /// underlying ScreenCaptureKit / model call has hung.
    private let maxCaptureBudget: TimeInterval = 60

    // Storyline decouples the FAST frame grab (~100ms) from the SLOW narration
    // (~15-20s), so no context switch is dropped while the model is thinking.
    private struct PendingFrame {
        let png: Data; let appName: String; let title: String
        let reason: String; let timestamp: Date; let depth: CaptureDepth
    }
    private var pendingFrames: [PendingFrame] = []   // main-actor only
    private let maxPendingFrames = 8                  // keep most-recent, bound memory
    private var grabbingFrame = false                 // one screen-grab at a time
    private var narrating = false                     // one narration at a time

    var sceneInterpreterName: String { interpreter.displayName }
    var onScreenshotSaved: (() -> Void)?

    private let store: Store
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// The span currently being accumulated.
    private var openSpan: (bundleID: String, appName: String, title: String, start: Date, docPath: String)?
    /// Raw title seen on the previous tick — a new title must be stable for two
    /// consecutive ticks before it splits the span (defeats ticking-clock titles).
    private var previousTickTitle: String?
    /// True between willSleep/sessionResign and the matching wake/active event;
    /// tick() is inert while set, so nothing is recorded for sleep or other users.
    private var suspended = false
    /// Watchdog: if wall-clock jumps far past the poll cadence (sleep without a
    /// notification, process freeze), the open span's tail is untrustworthy.
    private var lastTickDate = Date()

    /// Cached day-clipped total of saved spans for today; the published counter
    /// is this plus the open span's elapsed time, so no DB query per tick.
    private var savedTodaySeconds: TimeInterval = 0
    private var savedTodayDay = Calendar.current.startOfDay(for: Date())

    private let idleThreshold: TimeInterval = 3 * 60
    private let pollInterval: TimeInterval = 5

    init(store: Store) {
        self.store = store
        let defaults = UserDefaults.standard

        if let raw = defaults.string(forKey: "availeth.cap.telemetry"),
           let mode = InputTelemetryMode(rawValue: raw) {
            telemetryMode = mode
        } else if defaults.bool(forKey: "availeth.cap.input") {
            telemetryMode = .standard // migrate the earlier boolean capability
        } else {
            telemetryMode = .deep // default for a fresh install
        }
        if let raw = defaults.string(forKey: "availeth.cap.screenshotMode"),
           let m = ScreenshotMode(rawValue: raw) {
            screenshotMode = m
        } else if defaults.bool(forKey: "availeth.cap.screenshots") {
            screenshotMode = .thumbnails // migrate the earlier boolean
        } else {
            screenshotMode = .storyline // default for a fresh install
        }
        fileTrackingEnabled = defaults.bool(forKey: "availeth.cap.files")
        captureDepth = defaults.string(forKey: "availeth.cap.depth").flatMap(CaptureDepth.init) ?? .detailed

        // Exclusions: nothing is excluded by default now. The version-3 migration
        // strips the apps Availeth used to auto-exclude from existing installs,
        // while keeping any the user added themselves.
        if var saved = defaults.stringArray(forKey: Self.exclusionsKey).map(Set.init) {
            if defaults.integer(forKey: Self.exclusionsVersionKey) < 3 {
                saved.subtract(Self.legacyDefaultExclusions)
            }
            excludedBundleIDs = saved
        } else {
            excludedBundleIDs = Self.defaultExclusions
        }
        // `didSet` doesn't fire for init assignments, so persist the resolved set
        // explicitly — otherwise a migrated (stripped) list would revert on the
        // next launch, re-adding the apps we just removed.
        defaults.set(Array(excludedBundleIDs), forKey: Self.exclusionsKey)
        defaults.set(Self.exclusionsVersion, forKey: Self.exclusionsVersionKey)

        // Restore a still-active pause across launches.
        let pausedStamp = defaults.double(forKey: Self.pausedUntilKey)
        if pausedStamp > Date().timeIntervalSince1970 {
            pausedUntil = Date(timeIntervalSince1970: pausedStamp)
        }

        refreshSavedToday()
        observedTodaySeconds = savedTodaySeconds
    }

    /// Whether capture should start automatically this launch — false only when
    /// the user explicitly stopped discovery and never restarted it.
    var shouldObserveOnLaunch: Bool {
        UserDefaults.standard.object(forKey: Self.observingEnabledKey) == nil
            || UserDefaults.standard.bool(forKey: Self.observingEnabledKey)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isObserving else { return }
        isObserving = true
        suspended = false
        UserDefaults.standard.set(true, forKey: Self.observingEnabledKey)

        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ handler: @escaping () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in handler() })
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] in self?.tick() }
        observe(NSWorkspace.willSleepNotification) { [weak self] in self?.suspendCapture() }
        observe(NSWorkspace.didWakeNotification) { [weak self] in self?.resumeFromSuspension() }
        observe(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.suspendCapture() }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.resumeFromSuspension() }
        observe(NSWorkspace.willPowerOffNotification) { [weak self] in self?.closeOpenSpan() }

        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        lastTickDate = Date()
        lastPresentAt = Date() // an idle stretch can't predate this launch
        syncInputMonitor()
        pruneOldScreenshots()
        tick()
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false
        UserDefaults.standard.set(false, forKey: Self.observingEnabledKey)
        clearPause()
        timer?.invalidate()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers = []
        // Drain the final span's telemetry BEFORE tearing the monitor down.
        finalizeIdleSessionIfNeeded(returnedAt: Date())
        closeOpenSpan()
        inputMonitor.stop()
        pendingActionCapture?.cancel()
        // Invalidate any in-flight capture so its late completion can neither
        // store a frame nor race a capture started after a restart.
        captureGeneration &+= 1
        captureEpoch &+= 1
        captureInFlight = false
        // A grab in flight now has a stale generation (bumped above), so neither it
        // nor its watchdog will clear this flag — reset it here so a restart begins
        // clean. (An in-flight narration is left to finish and reset itself; its
        // stale epoch prevents it storing anything.)
        grabbingFrame = false
        pendingFrames.removeAll()
        setCurrentAppName(nil)
    }

    private let axQueue = DispatchQueue(label: "com.availeth.ax")

    /// Starts/stops the input monitor to match the mode and the FULLY-live state
    /// (observing, not paused, not suspended). The monitor is torn down whenever
    /// capture is not truly running, so nothing is watched during pause/sleep.
    private func syncInputMonitor() {
        inputMonitor.mode = telemetryMode
        inputMonitor.onNeedFieldRefresh = { [weak self] in self?.refreshFieldContextAsync() }
        inputMonitor.onAction = { [weak self] reason in self?.scheduleActionCapture(reason: reason) }
        let live = isObserving && !suspended && !isPaused
            && telemetryMode != .off && Permissions.inputMonitoringGranted
        if live {
            inputMonitor.start()
        } else {
            inputMonitor.stop()
        }
    }

    /// Off-main Accessibility read of the focused field, triggered while typing.
    /// Keeps the event callback non-blocking and the field label fresh across
    /// focus changes. Never runs for excluded/self apps.
    private func refreshFieldContextAsync() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              !excludedBundleIDs.contains(bundleID) else {
            inputMonitor.setCounting(false)
            return
        }
        let pid = front.processIdentifier
        let deep = telemetryMode == .deep
        axQueue.async { [weak self] in
            let info = AXReader.focusedElementLabel(pid: pid)
            DispatchQueue.main.async {
                guard let self,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                self.applyFieldContext(info, deep: deep)
            }
        }
    }

    /// Sets the monitor's per-field context: secure-ness and the label/class to
    /// attribute typing to. Only genuine text inputs get a label.
    private func applyFieldContext(_ info: (label: String, isSecure: Bool, isTextInput: Bool)?, deep: Bool) {
        guard let info else {
            inputMonitor.setField(label: "", secure: false, className: nil)
            return
        }
        let label = (info.isTextInput && !info.isSecure) ? info.label : ""
        let className = (deep && !label.isEmpty) ? FieldClassifier.classify(label) : nil
        inputMonitor.setField(label: label, secure: info.isSecure, className: className)
    }

    /// Process is exiting: persist the in-progress span without recording a
    /// "user turned discovery off" preference (unlike stop()).
    func shutdown() {
        timer?.invalidate()
        timer = nil
        finalizeIdleSessionIfNeeded(returnedAt: Date())
        closeOpenSpan()
    }

    /// Called when the user deletes their captured data: forget the in-progress
    /// span and recompute the today counter from the (now empty) store.
    func discardCurrentAndRefresh() {
        openSpan = nil
        previousTickTitle = nil
        refreshSavedToday()
        publishObservedToday()
    }

    private func suspendCapture() {
        suspended = true
        captureEpoch &+= 1 // invalidate any in-flight grab/narration from before the suspend
        finalizeIdleSessionIfNeeded(returnedAt: Date())
        closeOpenSpan()
        pendingFrames.removeAll() // drop un-narrated frames captured before sleep/switch
        inputMonitor.setCounting(false)
        syncInputMonitor() // tears the monitor down while suspended
        setCurrentAppName(nil)
    }

    private func resumeFromSuspension() {
        suspended = false
        lastTickDate = Date()
        syncInputMonitor()
        tick()
    }

    // MARK: - Pause

    var isPaused: Bool {
        if let until = pausedUntil { return until > Date() }
        return false
    }

    func pause(for interval: TimeInterval) {
        guard isObserving else { return }
        setPause(until: Date().addingTimeInterval(interval))
    }

    func pauseUntilTomorrow() {
        guard isObserving else { return }
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date().addingTimeInterval(12 * 3600)
        setPause(until: tomorrow)
    }

    func resume() {
        clearPause()
        if isObserving {
            tick()
        } else {
            start()
        }
    }

    private func setPause(until: Date) {
        pausedUntil = until
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: Self.pausedUntilKey)
        captureEpoch &+= 1 // invalidate any in-flight grab/narration from before the pause
        closeOpenSpan()
        pendingFrames.removeAll() // don't narrate frames captured just before pausing
        inputMonitor.setCounting(false)
        syncInputMonitor() // stops input monitoring for the pause window
        setCurrentAppName(nil)
    }

    private func clearPause() {
        pausedUntil = nil
        UserDefaults.standard.removeObject(forKey: Self.pausedUntilKey)
        syncInputMonitor() // restarts the monitor if capture is otherwise live
    }

    // MARK: - Core loop

    private func tick() {
        guard isObserving, !suspended else { return }
        let now = Date()

        // Watchdog: a wall-clock jump means we slept or froze without closing —
        // the open span's tail is unreliable, so end it at the last healthy tick.
        if openSpan != nil, now.timeIntervalSince(lastTickDate) > pollInterval * 3 {
            closeOpenSpan(end: lastTickDate)
        }
        lastTickDate = now
        rolloverDayIfNeeded()

        if isPaused {
            closeOpenSpan()
            inputMonitor.setCounting(false)
            setCurrentAppName(nil)
            publishObservedToday()
            return
        }
        if pausedUntil != nil {
            clearPause() // pause expired
        }

        // Idle: close the span backdated to when input actually stopped, so
        // away-from-keyboard time is never counted, and remember when the away
        // stretch began so it can be recorded as an idle session on return.
        let idleSeconds = systemIdleSeconds()
        if idleSeconds > idleThreshold {
            if idleSince == nil {
                // Input actually stopped `idleSeconds` ago, but never before the
                // last moment we knew the user was present (prevents overlap with
                // a prior idle stretch and pre-launch/pre-sleep starts).
                idleSince = IdleMath.idleStart(now: now, idleSeconds: idleSeconds, lastPresentAt: lastPresentAt)
            }
            closeOpenSpan(end: now.addingTimeInterval(-idleSeconds))
            inputMonitor.setCounting(false)
            setCurrentAppName("Away from keyboard")
            publishObservedToday()
            return
        }
        // Active again — close out any away stretch, and advance the present
        // watermark to the actual last input time.
        finalizeIdleSessionIfNeeded(returnedAt: now.addingTimeInterval(-idleSeconds))
        lastPresentAt = max(lastPresentAt, now.addingTimeInterval(-idleSeconds))

        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier else {
            closeOpenSpan()
            inputMonitor.setCounting(false)
            setCurrentAppName(nil)
            publishObservedToday()
            return
        }

        // Never observe ourselves.
        if bundleID == Bundle.main.bundleIdentifier {
            closeOpenSpan()
            inputMonitor.setCounting(false)
            setCurrentAppName(front.localizedName)
            publishObservedToday()
            return
        }

        // Local policy enforcement: excluded apps generate nothing, telemetry
        // included — the monitor stops counting while they are frontmost.
        if excludedBundleIDs.contains(bundleID) {
            closeOpenSpan()
            inputMonitor.setCounting(false)
            setCurrentAppName("Private (excluded)")
            publishObservedToday()
            return
        }

        let appName = front.localizedName ?? bundleID
        let pid = front.processIdentifier
        let rawTitle = AXReader.focusedWindowTitle(pid: pid) ?? ""
        setCurrentAppName(appName)
        // This context is capturable: let the monitor count, and refresh the
        // per-field label/secure context for attribution.
        inputMonitor.setCounting(telemetryMode != .off)
        if telemetryMode != .off {
            applyFieldContext(AXReader.focusedElementLabel(pid: pid), deep: telemetryMode == .deep)
        }
        // Keep the local-model status fresh so storyline recovers if Ollama
        // stops or restarts mid-session (and the UI reflects it).
        if screenshotMode == .storyline, now.timeIntervalSince(lastInterpreterCheck) > 10 {
            lastInterpreterCheck = now
            refreshInterpreterStatus()
        }
        defer {
            previousTickTitle = rawTitle
            publishObservedToday()
            maybeCaptureScreenshot(now: now, frontBundleID: bundleID, appName: appName, title: rawTitle)
        }

        if let span = openSpan {
            if span.bundleID == bundleID {
                let openNorm = Analytics.normalizeTitle(span.title, appName: appName)
                let newNorm = Analytics.normalizeTitle(rawTitle, appName: appName)
                let previousNorm = previousTickTitle.map { Analytics.normalizeTitle($0, appName: appName) }
                // Split only when the normalized title has changed AND held for
                // two consecutive ticks — live counters in titles never split.
                let stableNewTitle = newNorm != openNorm && newNorm == previousNorm
                if !stableNewTitle {
                    return // same context: keep accumulating
                }
            }
            closeOpenSpan(end: now)
        }
        // File identity (path only, never contents) — read once when the span opens.
        let docPath = (fileTrackingEnabled ? AXReader.focusedDocumentPath(pid: pid) : nil) ?? ""
        inputMonitor.reset() // start counting fresh for this span
        openSpan = (bundleID, appName, rawTitle, now, docPath)
    }

    private func closeOpenSpan(end: Date? = nil) {
        guard let span = openSpan else { return }
        openSpan = nil
        let endDate = min(max(end ?? Date(), span.start), Date())
        // Drain input telemetry regardless, so it doesn't bleed into the next span.
        let input = inputMonitor.drain()
        guard endDate.timeIntervalSince(span.start) >= 2 else { return }
        let telemetryOn = telemetryMode != .off
        store.insert(ActivitySpan(
            bundleID: span.bundleID,
            appName: span.appName,
            windowTitle: span.title,
            start: span.start,
            end: endDate,
            isDemo: false,
            keystrokes: telemetryOn ? input.keystrokes : 0,
            clicks: telemetryOn ? input.clicks : 0,
            documentPath: span.docPath,
            shortcuts: telemetryOn ? input.shortcuts : "",
            fields: telemetryOn ? input.fields : ""
        ))
        refreshSavedToday()
        onSpanSaved?()
    }

    // MARK: - Screenshots

    /// Tick-driven capture: on a context change (new app/window/tab) or the
    /// long interval fallback, but only while the user is present.
    private func maybeCaptureScreenshot(now: Date, frontBundleID: String, appName: String, title: String) {
        guard screenshotMode != .off,
              Permissions.screenRecordingGranted,
              !excludedBundleIDs.contains(frontBundleID) else { return }
        // Thumbnails hold captureInFlight through their (short) op; storyline
        // holds only grabbingFrame during the fast grab, so it doesn't block.
        if screenshotMode == .thumbnails && captureInFlight { return }
        if screenshotMode == .storyline && (grabbingFrame || !interpreterReady) { return }

        let context = frontBundleID + "|" + Analytics.normalizeTitle(title, appName: appName)
        let contextChanged = context != lastCaptureContext
        guard CaptureGate.shouldCapture(
            now: now,
            lastCaptureDate: lastScreenshotDate,
            lastContext: lastCaptureContext,
            currentContext: context,
            floor: captureFloor(),
            interval: captureInterval(),
            idleSeconds: systemIdleSeconds()
        ) else { return }

        let reason = contextChanged ? "Switched to \(Format.shortApp(appName))" : ""
        beginCapture(now: now, frontBundleID: frontBundleID, appName: appName, title: title, context: context, reason: reason)
    }

    /// Action-driven capture: fired (debounced) by the input monitor when the
    /// user copies, pastes, cuts, saves, or fills a field — the discrete steps a
    /// workflow is made of. Coalesces rapid actions into one capture.
    private func scheduleActionCapture(reason: String) {
        guard screenshotMode != .off, Permissions.screenRecordingGranted else { return }
        pendingActionReason = reason
        // Remember which app the action happened in; the debounced capture may
        // fire up to `floor` seconds later, by which point the front app could
        // have changed — we must not label an unrelated frame "Pasted".
        pendingActionBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        pendingActionCapture?.cancel()
        let sinceLast = Date().timeIntervalSince(lastScreenshotDate)
        // Small settle delay so the screen reflects the action; never below the floor.
        let delay = max(0.4, captureFloor() - sinceLast)
        let work = DispatchWorkItem { [weak self] in self?.fireActionCapture() }
        pendingActionCapture = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fireActionCapture() {
        guard isObserving, !suspended, !isPaused,
              screenshotMode != .off, Permissions.screenRecordingGranted,
              !(screenshotMode == .thumbnails && captureInFlight),
              !(screenshotMode == .storyline && grabbingFrame),
              systemIdleSeconds() < idleThreshold,
              Date().timeIntervalSince(lastScreenshotDate) >= captureFloor(),
              let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              !excludedBundleIDs.contains(bundleID) else { return }
        if screenshotMode == .storyline && !interpreterReady { return }
        let appName = front.localizedName ?? bundleID
        let title = AXReader.focusedWindowTitle(pid: front.processIdentifier) ?? ""
        let context = bundleID + "|" + Analytics.normalizeTitle(title, appName: appName)
        // Only attach the action label if we're still in the app the action
        // happened in; otherwise capture the frame with no (misleading) reason.
        let reason = (bundleID == pendingActionBundleID) ? pendingActionReason : ""
        beginCapture(now: Date(), frontBundleID: bundleID, appName: appName, title: title, context: context, reason: reason)
    }

    /// Shared capture kickoff for both tick- and action-driven paths.
    ///
    /// captureInFlight is cleared by wall-clock, NOT by the op finishing: a
    /// generation token identifies each capture, and a main-queue watchdog clears
    /// the flag after maxCaptureBudget even if ScreenCaptureKit hangs (a real
    /// macOS failure mode that a structured task-group timeout can NOT bound,
    /// because the group awaits the hung child at scope exit). The token also
    /// ensures a late/abandoned op can never store its result or clear a newer
    /// capture's flag.
    private func beginCapture(now: Date, frontBundleID: String, appName: String, title: String, context: String, reason: String) {
        lastScreenshotDate = now
        lastCaptureContext = context
        let excluded = excludedBundleIDs

        if screenshotMode == .thumbnails {
            guard !captureInFlight else { return }
            captureGeneration &+= 1
            let gen = captureGeneration
            captureInFlight = true
            DispatchQueue.main.asyncAfter(deadline: .now() + maxCaptureBudget) { [weak self] in
                guard let self, self.captureGeneration == gen, self.captureInFlight else { return }
                self.captureInFlight = false
            }
            Task { [weak self] in
                guard let self else { return }
                _ = await self.runThumbnailCapture(now: now, appName: appName, title: title, excluded: excluded, generation: gen)
                await MainActor.run { if self.captureGeneration == gen { self.captureInFlight = false } }
            }
            return
        }

        // Storyline: grab the frame NOW (fast), enqueue it, and let the narration
        // worker catch up — so a slow model never causes a missed capture.
        guard !grabbingFrame else { return }
        // Same generation-token watchdog the thumbnail path uses: if the grab's
        // ScreenCaptureKit call HANGS (a real macOS failure mode a structured
        // timeout can't bound), grabbingFrame would otherwise stay true forever and
        // silently kill storyline capture for the whole session. Free it after the
        // budget if the same grab is still outstanding.
        captureGeneration &+= 1
        let gen = captureGeneration
        let epoch = captureEpoch
        grabbingFrame = true
        DispatchQueue.main.asyncAfter(deadline: .now() + maxCaptureBudget) { [weak self] in
            guard let self, self.captureGeneration == gen, self.grabbingFrame else { return }
            self.grabbingFrame = false // grab hung past budget — recover
        }
        let depth = captureDepth
        Task { [weak self] in
            guard let self else { return }
            let cg = await self.screenshotCapture.captureDisplay(excludedBundleIDs: excluded)
            let png = cg.flatMap { self.screenshotCapture.encodeForModel($0) }
            await MainActor.run {
                guard self.captureGeneration == gen else { return } // watchdog/stop superseded us
                self.grabbingFrame = false
                guard self.captureEpoch == epoch,           // not invalidated mid-grab
                      let png,
                      self.isObserving, !self.isPaused, !self.suspended,
                      self.screenshotMode == .storyline, !self.frontmostIsExcluded() else { return }
                self.pendingFrames.append(PendingFrame(png: png, appName: appName, title: title, reason: reason, timestamp: now, depth: depth))
                if self.pendingFrames.count > self.maxPendingFrames {
                    self.pendingFrames.removeFirst(self.pendingFrames.count - self.maxPendingFrames)
                }
                self.drainNarration()
            }
        }
    }

    /// Serially narrates queued frames. Frames are captured immediately; this
    /// catches up at the model's pace without ever blocking a capture.
    private func drainNarration() {
        guard !narrating, interpreterReady, screenshotMode == .storyline,
              !pendingFrames.isEmpty else { return }
        narrating = true
        let epoch = captureEpoch
        let frame = pendingFrames.removeFirst()
        Task { [weak self] in
            guard let self else { return }
            let narrative = await self.interpreter.narrate(
                pngData: frame.png,
                context: SceneContext(appName: frame.appName, windowTitle: frame.title, action: frame.reason, depth: frame.depth))
            await MainActor.run {
                if let narrative {
                    // Epoch guard: a stop/suspend/pause/mode-change during the
                    // ~15-20s narration invalidates this frame — don't store it.
                    if self.captureEpoch == epoch && self.isObserving && !self.isPaused && !self.suspended && self.screenshotMode == .storyline {
                        let url = self.screenshotCapture.writeReviewImage(frame.png)
                        self.store.insertNarrative(SceneNarrative(
                            timestamp: frame.timestamp, appName: frame.appName, windowTitle: frame.title,
                            text: narrative, imagePath: url?.path ?? "", trigger: frame.reason, isDemo: false))
                        self.onScreenshotSaved?()
                        self.pruneOldNarratives()
                    }
                } else {
                    self.interpreterReady = false // model went away; keep queued frames for retry
                }
                self.narrating = false
                self.drainNarration()
            }
        }
    }

    /// Whether it is still valid to persist a capture that started earlier —
    /// guards against storing a frame after pause/stop/mode-change/exclusion, or
    /// after the capture was superseded/abandoned (generation changed).
    @MainActor
    private func stillCapturing(_ mode: ScreenshotMode, generation: Int, frontExcluded: Bool) -> Bool {
        captureGeneration == generation && isObserving && !isPaused && !suspended && screenshotMode == mode && !frontExcluded
    }

    private func frontmostIsExcluded() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return true }
        return id == Bundle.main.bundleIdentifier || excludedBundleIDs.contains(id)
    }

    /// Thumbnails: redacted image stored on disk (24h retention).
    private func runThumbnailCapture(now: Date, appName: String, title: String, excluded: Set<String>, generation: Int) async -> Bool {
        let url = await screenshotCapture.captureRedacted(excludedBundleIDs: excluded)
        return await MainActor.run {
            guard let url else { return false }
            guard self.stillCapturing(.thumbnails, generation: generation, frontExcluded: self.frontmostIsExcluded()) else {
                ScreenshotCapture.deleteFiles([url.path]); return false
            }
            self.store.insertScreenshot(Screenshot(timestamp: now, appName: appName, windowTitle: title, path: url.path, isDemo: false))
            self.onScreenshotSaved?()
            self.pruneOldScreenshots()
            return true
        }
    }

    /// Storyline: capture → local model narrates → store text → discard image.
    /// The PNG never touches disk; it lives only for the duration of the call.
    private func pruneOldNarratives() {
        let cutoff = Date().addingTimeInterval(-screenshotRetention)
        let paths = store.pruneNarratives(olderThan: cutoff)
        ScreenshotCapture.deleteFiles(paths)
    }

    /// Records the away stretch (if long enough) when the user returns.
    private func finalizeIdleSessionIfNeeded(returnedAt: Date) {
        guard let start = idleSince else { return }
        idleSince = nil
        // End at the actual return, clamped to be after the start and no later
        // than now; advance the present-watermark so the next idle stretch can
        // never re-open this one.
        let end = IdleMath.idleEnd(start: start, returnedAt: returnedAt, now: Date())
        lastPresentAt = max(lastPresentAt, end)
        guard end.timeIntervalSince(start) >= minIdleToRecord else { return }
        store.insertIdleSession(IdleSession(start: start, end: end, isDemo: false))
        onIdleRecorded?()
    }

    func refreshInterpreterStatus() {
        Task { [weak self] in
            guard let self else { return }
            let ready = await self.interpreter.isAvailable()
            await MainActor.run {
                self.interpreterReady = ready
                if ready { self.drainNarration() } // model came back — process queued frames
            }
        }
    }

    private func pruneOldScreenshots() {
        let cutoff = Date().addingTimeInterval(-screenshotRetention)
        let paths = store.pruneScreenshots(olderThan: cutoff)
        ScreenshotCapture.deleteFiles(paths)
    }

    /// Deletes every live screenshot and narrative (rows + image files) — used
    /// on data delete.
    func purgeAllLiveScreenshots() {
        ScreenshotCapture.deleteFiles(store.deleteScreenshots(scope: .live))
        ScreenshotCapture.deleteFiles(store.deleteNarratives(scope: .live))
    }

    private func systemIdleSeconds() -> TimeInterval {
        // Seconds since the last HARDWARE input (keyboard/mouse/trackpad). Uses
        // .hidSystemState — NOT .combinedSessionState — so background/synthetic
        // events (autoplay video, notifications, helper apps) don't count as the
        // human being present. This is what makes "away at the gym" register as
        // idle instead of active work.
        let anyInput = unsafeBitCast(~UInt32(0), to: CGEventType.self)
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }

    // MARK: - Published state (guarded writes: no redundant UI invalidation)

    private func setCurrentAppName(_ name: String?) {
        if currentAppName != name { currentAppName = name }
    }

    /// Today counter = day-clipped saved total + the open span's elapsed time.
    private func publishObservedToday() {
        let dayStart = Calendar.current.startOfDay(for: Date())
        var total = savedTodaySeconds
        if let span = openSpan {
            total += Date().timeIntervalSince(max(span.start, dayStart))
        }
        let rounded = total.rounded()
        if rounded != observedTodaySeconds { observedTodaySeconds = rounded }
    }

    private func rolloverDayIfNeeded() {
        let dayStart = Calendar.current.startOfDay(for: Date())
        if dayStart != savedTodayDay {
            refreshSavedToday()
        }
    }

    private func refreshSavedToday() {
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)
        savedTodayDay = dayStart
        let spans = store.spans(from: dayStart, to: now.addingTimeInterval(60), demo: false)
        // Clip each span to today so overnight spans never inflate the counter.
        savedTodaySeconds = spans.reduce(0) { acc, span in
            acc + max(0, min(span.end, now).timeIntervalSince(max(span.start, dayStart)))
        }
    }
}
