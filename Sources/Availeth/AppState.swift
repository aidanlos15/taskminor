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

    private var cancellables: Set<AnyCancellable> = []
    private var synthTimer: Timer?

    private init() {
        let store = Store(url: Store.defaultURL())
        self.store = store
        self.engine = CaptureEngine(store: store)
        self.synthesizer = Synthesizer(store: store, interpreter: OllamaInterpreter())

        let defaults = UserDefaults.standard
        if defaults.object(forKey: "availeth.showDemo") == nil {
            // The very first intro only: the sample dataset stands in so the
            // dashboard is not empty before anything has been observed. Once
            // onboarding is finished it switches to real activity and stays
            // there; after that the sample is only reachable from the Privacy
            // tab, so nobody mistakes a made-up finance department for their own
            // work.
            showDemo = !defaults.bool(forKey: WelcomeSheet.onboardedKey)
        } else {
            showDemo = defaults.bool(forKey: "availeth.showDemo")
        }
        let rate = defaults.double(forKey: "availeth.hourlyRate")
        hourlyRate = rate > 0 ? rate : 45

        // Default to Light on first launch; honor the saved choice thereafter.
        themeMode = (defaults.string(forKey: "availeth.theme")).flatMap(ThemeMode.init) ?? .light

        // The engine republishes the open span about once a second; forward that
        // to the views so totals and lists move in real time.
        engine.$liveSpan
            .removeDuplicates { $0?.end == $1?.end }
            .sink { [weak self] _ in self?.dataVersion += 1 }
            .store(in: &cancellables)

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
        // Forward engine changes (pause state, current app) to our observers.
        engine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func bootstrap() {
        if store.spanCount(demo: true) == 0 {
            store.insertBatch(DemoData.generate())
        }
        if store.narrativeCount(demo: true) == 0 {
            DemoData.generateNarratives().forEach { store.insertNarrative($0) }
        }
        if store.transferCount(demo: true) == 0 {
            DemoData.generateTransfers().forEach { store.insert(transfer: $0) }
        }
        if store.idleSessions(from: .distantPast, to: .distantFuture, demo: true).isEmpty {
            DemoData.generateIdleSessions().forEach { store.insertIdleSession($0) }
        }
        if store.taskSummaries(from: .distantPast, to: .distantFuture, demo: true).isEmpty {
            DemoData.seedSummaries(into: store)
        }
        // Consent before capture. On a first launch the welcome sheet is about to
        // appear, and starting to record behind it meant the database already held
        // the person's activity while the consent screen sat unanswered. Capture
        // waits for that sheet; on every later launch it behaves as before, and a
        // persisted Stop is still honoured (an expired pause resumes, an active
        // one holds).
        let onboarded = UserDefaults.standard.bool(forKey: WelcomeSheet.onboardedKey)
        if onboarded && engine.shouldObserveOnLaunch {
            engine.start()
        }
        // Start (or find) the local model service before asking what it has.
        // With the server bundled there is nothing for the customer to install.
        Task { @MainActor in
            await OllamaService.shared.ensureRunning()
            self.engine.refreshInterpreterStatus()
        }
        engine.refreshInterpreterStatus()
        dataVersion += 1
        refreshTodayTopApps()

        // Periodically fuse raw signals into minute → task summaries (local model).
        let t = Timer(timeInterval: 90, repeats: true) { [weak self] _ in self?.runSynthesis() }
        RunLoop.main.add(t, forMode: .common)
        synthTimer = t
        runSynthesis()
    }

    private func runSynthesis() {
        Task { [weak self] in
            guard let self else { return }
            await self.synthesizer.run()
            await MainActor.run { self.dataVersion += 1 }
        }
    }

    private func refreshTodayTopApps() {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let spans = store.spans(from: dayStart, to: Date().addingTimeInterval(60), demo: false)
        todayTopApps = Array(Analytics.timeByApp(spans).prefix(3))
    }

    // MARK: - Queries

    /// Stored spans plus the one in progress, so the dashboard shows the current
    /// app growing rather than freezing until the next app switch writes a row.
    func spans(in range: TimeRange) -> [ActivitySpan] {
        var out = store.spans(from: range.startDate(), to: Date().addingTimeInterval(60), demo: showDemo)
        if !showDemo, let live = engine.liveSpan, live.end > range.startDate() {
            out.append(live)
        }
        return out
    }

    var liveSpanCount: Int { store.spanCount(demo: false) }

    // MARK: - Data management

    func deleteLiveData() {
        store.deleteLiveData()
        engine.purgeAllLiveScreenshots()
        store.deleteSummaries(scope: .live)
        store.deleteIdleSessions(scope: .live)
        engine.discardCurrentAndRefresh()
        dataVersion += 1
        refreshTodayTopApps()
    }

    func resetDemoData() {
        store.deleteAll(demoOnly: true)
        store.deleteNarratives(scope: .demo)
        store.deleteIdleSessions(scope: .demo)
        store.deleteSummaries(scope: .demo)
        store.insertBatch(DemoData.generate())
        DemoData.generateNarratives().forEach { store.insertNarrative($0) }
        DemoData.generateTransfers().forEach { store.insert(transfer: $0) }
        DemoData.generateIdleSessions().forEach { store.insertIdleSession($0) }
        DemoData.seedSummaries(into: store)
        dataVersion += 1
    }

    // MARK: - Story queries

    func taskSummaries(in range: TimeRange) -> [TaskSummary] {
        store.taskSummaries(from: range.startDate(), to: Date().addingTimeInterval(60), demo: showDemo)
    }

    func minutes(forTask id: Int64) -> [MinuteSummary] {
        store.minutesForTask(id)
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
