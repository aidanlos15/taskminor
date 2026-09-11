import AppKit
import Combine
import ServiceManagement

/// The app's visual appearance. Light is the default.
enum ThemeMode: String {
    case light, dark
}

/// Central wiring: owns the store and capture engine, exposes query helpers,
/// and versions the data so views refresh when new spans land.
final class AppState: ObservableObject {
    static let shared = AppState()

    let store: Store
    let engine: CaptureEngine

    /// Bumped whenever underlying data changes; views recompute on change.
    @Published private(set) var dataVersion = 0

    /// Cached top apps for today's live capture — read by the menu bar panel so
    /// it never runs store queries during view rendering.
    @Published private(set) var todayTopApps: [AppTotal] = []

    /// Set to true to reopen the first-run welcome/permissions sheet.
    @Published var welcomeRequested = false

    /// True → dashboard shows the bundled demo dataset; false → live capture.
    @Published var showDemo: Bool {
        didSet { UserDefaults.standard.set(showDemo, forKey: "availeth.showDemo") }
    }

    /// The app's visual appearance. Defaults to Light; the user flips it from the
    /// sidebar footer. Drives NSApp.appearance, which re-resolves every adaptive
    /// Theme token and the window chrome in one shot.
    @Published var themeMode: ThemeMode {
        didSet {
            UserDefaults.standard.set(themeMode.rawValue, forKey: "availeth.theme")
            applyAppearance()
        }
    }

    /// Applies the selected appearance to the whole app (all windows + adaptive
    /// colors). Safe to call repeatedly; call once at launch to honor the default.
    func applyAppearance() {
        NSApp.appearance = NSAppearance(named: themeMode == .dark ? .darkAqua : .aqua)
    }

    /// Loaded labour rate used for $ estimates.
    @Published var hourlyRate: Double {
        didSet { UserDefaults.standard.set(hourlyRate, forKey: "availeth.hourlyRate") }
    }

    let synthesizer: Synthesizer
    /// Names sittings of work by intent for the Tasks tab (same local model).
    let labeler: IntentLabeler

    private var cancellables: Set<AnyCancellable> = []
    private var synthTimer: Timer?
    /// The in-flight synthesis → labelling chain; a tick is skipped while the
    /// previous one is still running, so the two never overlap on the model.
    private var pipelineTask: Task<Void, Never>?

    private init() {
        let store = Store(url: Store.defaultURL())
        self.store = store
        self.engine = CaptureEngine(store: store)
        let interpreter = OllamaInterpreter()
        self.synthesizer = Synthesizer(store: store, interpreter: interpreter)
        self.labeler = IntentLabeler(store: store, interpreter: interpreter)
        SiteIconStore.shared.attach(store: store)

        let defaults = UserDefaults.standard
        if defaults.object(forKey: "availeth.showDemo") == nil {
            // First launch: show the demo dataset so the dashboard is alive immediately.
            showDemo = true
        } else {
            showDemo = defaults.bool(forKey: "availeth.showDemo")
        }
        let rate = defaults.double(forKey: "availeth.hourlyRate")
        hourlyRate = rate > 0 ? rate : 45

        // Default to Light on first launch; honor the saved choice thereafter.
        themeMode = (defaults.string(forKey: "availeth.theme")).flatMap(ThemeMode.init) ?? .light

        engine.onSpanSaved = { [weak self] in
            DispatchQueue.main.async {
                self?.dataVersion += 1
                self?.refreshTodayTopApps()
            }
        }
        engine.onScreenshotSaved = { [weak self] in
            DispatchQueue.main.async { self?.dataVersion += 1 }
        }
        engine.onIdleRecorded = { [weak self] in
            DispatchQueue.main.async { self?.dataVersion += 1 }
        }
        // A site's icon arrived: forget the lettermark and let every screen repaint.
        SiteIconStore.shared.onIconStored = { [weak self] domain in
            DispatchQueue.main.async {
                LogoProvider.shared.invalidate(site: domain)
                self?.dataVersion += 1
            }
        }
        // Forward engine changes (pause state, current app) to our observers.
        engine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func bootstrap() {
        // The demo generator changed (Claude sittings + intent labels): rebuild
        // the demo dataset once for installs that seeded the older one. A fresh
        // install seeds below instead and records the version.
        let demoVersion = 2
        let seededVersion = UserDefaults.standard.integer(forKey: "availeth.demoVersion")
        if seededVersion < demoVersion, store.spanCount(demo: true) > 0 {
            resetDemoData()
        } else {
            if store.spanCount(demo: true) == 0 {
                store.insertBatch(DemoData.generate())
            }
            if store.narrativeCount(demo: true) == 0 {
                DemoData.generateNarratives().forEach { store.insertNarrative($0) }
            }
            if store.idleSessions(from: .distantPast, to: .distantFuture, demo: true).isEmpty {
                DemoData.generateIdleSessions().forEach { store.insertIdleSession($0) }
            }
            if store.taskSummaries(from: .distantPast, to: .distantFuture, demo: true).isEmpty {
                DemoData.seedSummaries(into: store)
            }
            if store.spanLabelCount(demo: true) == 0 {
                DemoData.seedSpanLabels(into: store)
            }
        }
        UserDefaults.standard.set(demoVersion, forKey: "availeth.demoVersion")

        // One-time sweep of system-process rows (lock screen, Wi-Fi sign-in,
        // auth prompts) recorded before they were filtered at capture, and of
        // app names carrying invisible format marks.
        let purgeVersion = 1
        if UserDefaults.standard.integer(forKey: "availeth.systemPurgeVersion") < purgeVersion {
            store.deleteSpans(bundleIDs: SystemProcesses.bundleIDs)
            ScreenshotCapture.deleteFiles(store.deleteNarratives(appNames: SystemProcesses.appNames))
            store.normaliseAppNames()
            UserDefaults.standard.set(purgeVersion, forKey: "availeth.systemPurgeVersion")
        }
        // Honor a persisted Stop: capture never silently restarts after the
        // user turned it off. (An expired pause resumes; an active one holds.)
        if engine.shouldObserveOnLaunch {
            engine.start()
        }
        if engine.screenshotMode == .storyline {
            engine.refreshInterpreterStatus()
        }
        dataVersion += 1
        refreshTodayTopApps()

        // Periodically fuse raw signals into minute → task summaries (local model).
        let t = Timer(timeInterval: 90, repeats: true) { [weak self] _ in self?.runSynthesis() }
        RunLoop.main.add(t, forMode: .common)
        synthTimer = t
        runSynthesis()
    }

    private func runSynthesis() {
        guard pipelineTask == nil else { return }   // previous tick still on the model
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            await self.synthesizer.run()
            await self.labeler.run()
            await MainActor.run {
                self.dataVersion += 1
                self.pipelineTask = nil
            }
        }
    }

    private func refreshTodayTopApps() {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let spans = store.spans(from: dayStart, to: Date().addingTimeInterval(60), demo: false)
        todayTopApps = Array(Analytics.timeByApp(spans).prefix(3))
    }

    // MARK: - Queries

    func spans(in range: TimeRange) -> [ActivitySpan] {
        store.spans(from: range.startDate(), to: Date().addingTimeInterval(60), demo: showDemo)
    }

    var liveSpanCount: Int { store.spanCount(demo: false) }

    // MARK: - Data management

    func deleteLiveData() {
        store.deleteLiveData()
        engine.purgeAllLiveScreenshots()
        store.deleteSummaries(scope: .live)
        store.deleteIdleSessions(scope: .live)
        // Live span labels went with their spans (deleteLiveData sweeps orphans).
        SiteIconStore.shared.purgeAll()
        LogoProvider.shared.invalidateAllSites()
        engine.discardCurrentAndRefresh()
        dataVersion += 1
        refreshTodayTopApps()
    }

    func resetDemoData() {
        store.deleteAll(demoOnly: true)   // also sweeps the demo spans' labels
        store.deleteNarratives(scope: .demo)
        store.deleteIdleSessions(scope: .demo)
        store.deleteSummaries(scope: .demo)
        store.insertBatch(DemoData.generate())
        DemoData.generateNarratives().forEach { store.insertNarrative($0) }
        DemoData.generateIdleSessions().forEach { store.insertIdleSession($0) }
        DemoData.seedSummaries(into: store)
        DemoData.seedSpanLabels(into: store)
        dataVersion += 1
    }

    // MARK: - Launch at login

    var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            objectWillChange.send()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
