import AppKit
import SwiftUI

struct PrivacyView: View {
    @EnvironmentObject private var state: AppState

    @State private var axTrusted = AXReader.isTrusted
    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?
    @State private var confirmDeleteLive = false
    @State private var liveSpanCount = 0
    @State private var liveNarrativeCount = 0
    @State private var liveScreenshotCount = 0
    @State private var exclusionNames: [String: String] = [:]

    private var dataSummary: String {
        var parts = ["\(liveSpanCount) activity records"]
        if liveNarrativeCount > 0 { parts.append("\(liveNarrativeCount) storyline notes") }
        if liveScreenshotCount > 0 { parts.append("\(liveScreenshotCount) thumbnails") }
        return parts.joined(separator: " · ") + " captured"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard
                windowTitlesCard
                capabilitiesCard
                exclusionsCard
                dataCard
                neverCollectedCard
            }
            .padding(20)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear {
            launchAtLogin = state.launchAtLoginEnabled
            refreshDataCounts()
            refreshExclusionNames()
        }
        .onChange(of: state.dataVersion) { refreshDataCounts() }
        .onChange(of: state.engine.excludedBundleIDs) { refreshExclusionNames() }
        .task {
            // Poll the Accessibility grant while this tab is visible; the task
            // is cancelled automatically when the view goes away.
            while !Task.isCancelled {
                axTrusted = AXReader.isTrusted
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refreshDataCounts() {
        liveSpanCount = state.liveSpanCount
        liveNarrativeCount = state.store.narrativeCount(demo: false)
        liveScreenshotCount = state.store.screenshotCount(demo: false)
    }

    private func refreshExclusionNames() {
        var names: [String: String] = [:]
        for bundleID in state.engine.excludedBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                names[bundleID] = FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: "")
            } else {
                names[bundleID] = bundleID
            }
        }
        exclusionNames = names
    }

    // MARK: - Capture status

    private var statusCard: some View {
        Card(title: "Discovery", subtitle: "What Availeth is doing right now") {
            HStack(spacing: 12) {
                Circle()
                    .fill(state.engine.isPaused ? Color.orange : (state.engine.isObserving ? Color.green : Color.secondary))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle).font(.body.weight(.medium))
                    Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if state.engine.isPaused {
                    Button("Resume") { state.engine.resume() }
                        .buttonStyle(.borderedProminent).tint(.indigo)
                } else if state.engine.isObserving {
                    Menu("Pause") {
                        Button("For 15 minutes") { state.engine.pause(for: 15 * 60) }
                        Button("For 1 hour") { state.engine.pause(for: 3600) }
                        Button("Until tomorrow") { state.engine.pauseUntilTomorrow() }
                    }
                    .frame(width: 90)
                    Button("Stop") { state.engine.stop() }
                } else {
                    Button("Start Discovery") { state.engine.start() }
                        .buttonStyle(.borderedProminent).tint(.indigo)
                }
            }

            Divider()

            Toggle(isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    launchAtLoginError = state.setLaunchAtLogin(newValue)
                    launchAtLogin = state.launchAtLoginEnabled
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Start Availeth at login")
                    Text("Keeps discovery running across restarts")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            if let launchAtLoginError {
                Text(launchAtLoginError).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var statusTitle: String {
        if state.engine.isPaused { return "Paused" }
        return state.engine.isObserving ? "Discovery active" : "Discovery stopped"
    }

    private var statusDetail: String {
        if state.engine.isPaused, let until = state.engine.pausedUntil {
            return "Resumes \(until.formatted(date: .omitted, time: .shortened))"
        }
        if state.engine.isObserving {
            return state.engine.currentAppName.map { "Currently observing: \($0)" } ?? "Waiting for activity"
        }
        return "No activity is being recorded"
    }

    // MARK: - Window titles / Accessibility

    private var windowTitlesCard: some View {
        Card(title: "Window-title capture", subtitle: "Optional — makes task grouping much richer") {
            HStack(spacing: 12) {
                Image(systemName: axTrusted ? "checkmark.seal.fill" : "seal")
                    .font(.title3)
                    .foregroundStyle(axTrusted ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(axTrusted ? "Enabled" : "Not enabled")
                        .font(.body.weight(.medium))
                    Text(axTrusted
                         ? "Availeth reads the focused window's title (e.g. “Purchase Orders.xlsx”) via macOS Accessibility. Read-only by design — Availeth never controls anything."
                         : "Without this, Availeth only sees which app is frontmost. Grant Accessibility in System Settings to group time by document and page titles.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !axTrusted {
                    Button("Enable…") {
                        AXReader.requestTrust()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                }
            }
        }
    }

    // MARK: - Additional capabilities

    @State private var screenRecordingGranted = Permissions.screenRecordingGranted
    @State private var inputMonitoringGranted = Permissions.inputMonitoringGranted

    private var capabilitiesCard: some View {
        Card(title: "Additional capture", subtitle: "Each is off by default, needs its own permission, and is shown in full in the Logs tab") {
            HStack {
                Spacer()
                Button {
                    state.welcomeRequested = true
                } label: {
                    Label("Setup guide & permissions", systemImage: "sparkles")
                }
                .controlSize(.small)
            }
            interactionTelemetryRow
            Divider()
            screenCaptureRow
            Divider()
            capabilityRow(
                icon: "doc.text.magnifyingglass",
                title: "File tracking (identity only)",
                on: Binding(get: { state.engine.fileTrackingEnabled }, set: { state.engine.fileTrackingEnabled = $0 }),
                granted: axTrusted,
                needsLabel: "Needs Window Titles (Accessibility)",
                explanation: "Records which document is open in the focused window (its name and path) to enrich workflows — never the file's contents. Uses the Accessibility permission; no Full Disk Access.",
                request: {
                    AXReader.requestTrust()
                    openSettings("com.apple.preference.security?Privacy_Accessibility")
                }
            )

            Label {
                Text("Raw keystroke content and file contents are deliberately not collected — the counts and identities above give the workflow signal without the sensitive data.")
                    .font(.caption).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "info.circle").foregroundStyle(.indigo)
            }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            screenRecordingGranted = Permissions.screenRecordingGranted
            inputMonitoringGranted = Permissions.inputMonitoringGranted
        }
    }

    private var screenCaptureRow: some View {
        let mode = Binding(
            get: { state.engine.screenshotMode },
            set: { state.engine.screenshotMode = $0 }
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "camera.viewfinder")
                    .frame(width: 22)
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen capture")
                        .font(.callout.weight(.medium))
                    Text("Captures on screen changes to fill in workflows the other signals can't see.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker("", selection: mode) {
                    ForEach(ScreenshotMode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 230)
            }
            Text(state.engine.screenshotMode.blurb)
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 32)
                .fixedSize(horizontal: false, vertical: true)

            if state.engine.screenshotMode != .off && !screenRecordingGranted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Text("Needs Screen Recording — grant it, then relaunch Availeth.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Grant…") {
                        Permissions.requestScreenRecording()
                        openSettings("com.apple.preference.security?Privacy_ScreenCapture")
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 32)
            }
            if state.engine.screenshotMode == .storyline {
                HStack(spacing: 8) {
                    Circle().fill(state.engine.interpreterReady ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(state.engine.interpreterReady
                         ? "Local model ready: \(state.engine.sceneInterpreterName)"
                         : "Local model not reachable — start Ollama and pull a vision model (e.g. qwen2.5vl:7b).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 32)

                // Depth dial: how much the model reads from each frame.
                let depth = Binding(get: { state.engine.captureDepth }, set: { state.engine.captureDepth = $0 })
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Detail level").font(.caption.weight(.medium))
                        Picker("", selection: depth) {
                            ForEach(CaptureDepth.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 190)
                    }
                    Text(state.engine.captureDepth.blurb)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if state.engine.captureDepth == .detailed {
                        Label("Detailed mode reads on-screen content (text, values, AI questions) into the story. Only use where you have consent.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 32)
            }
        }
        .onAppear { if state.engine.screenshotMode == .storyline { state.engine.refreshInterpreterStatus() } }
    }

    private var interactionTelemetryRow: some View {
        let mode = Binding(
            get: { state.engine.telemetryMode },
            set: { state.engine.telemetryMode = $0 }
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "keyboard")
                    .frame(width: 22)
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard & mouse activity")
                        .font(.callout.weight(.medium))
                    Text("Sees how a task is done — which shortcuts you use, how you move between fields, how much typing it takes — but never records the actual keys you press.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker("", selection: mode) {
                    ForEach(InputTelemetryMode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
            }
            Text(state.engine.telemetryMode.blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 32)
                .fixedSize(horizontal: false, vertical: true)
            if state.engine.telemetryMode != .off && !inputMonitoringGranted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Text("Needs Input Monitoring — grant it, then relaunch Availeth.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Grant…") { requestInputMonitoring() }
                    .controlSize(.small)
                }
                .padding(.leading, 32)
            }
            if state.engine.telemetryMode != .off && inputMonitoringGranted && !axTrusted {
                Text("Shortcuts and counts work now. Field names also need Window Titles (Accessibility), enabled above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 32)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func capabilityRow(icon: String, title: String, on: Binding<Bool>, granted: Bool, needsLabel: String, explanation: String, request: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 22)
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(explanation)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: on)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            if on.wrappedValue && !granted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Text("\(needsLabel) — grant it for this to capture anything.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Grant…", action: request)
                        .controlSize(.small)
                }
                .padding(.leading, 32)
            }
        }
    }

    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Requests Input Monitoring, then opens the pane after a short delay so the
    /// system prompt (if any) has a chance to appear first rather than being
    /// hidden behind System Settings.
    private func requestInputMonitoring() {
        _ = Permissions.requestInputMonitoring()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            openSettings("com.apple.preference.security?Privacy_ListenEvent")
        }
    }

    // MARK: - Exclusions

    private var exclusionsCard: some View {
        Card(title: "Excluded apps", subtitle: "Availeth records nothing at all while these are in front — enforced locally, before anything is stored") {
            VStack(alignment: .leading, spacing: 8) {
                if state.engine.excludedBundleIDs.isEmpty {
                    Text("No exclusions configured.")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    FlowLayoutish(items: state.engine.excludedBundleIDs.sorted()) { bundleID in
                        HStack(spacing: 5) {
                            Text(displayName(for: bundleID))
                                .font(.caption)
                            Button {
                                state.engine.excludedBundleIDs.remove(bundleID)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove exclusion")
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.quaternary.opacity(0.6)))
                    }
                }

                Menu {
                    ForEach(runningApps, id: \.bundleID) { app in
                        Button(app.name) {
                            state.engine.excludedBundleIDs.insert(app.bundleID)
                        }
                    }
                } label: {
                    Label("Exclude a running app…", systemImage: "plus.circle")
                }
                .frame(maxWidth: 240)

                Text("Exclusions work per app. Private browser windows can't be told apart from normal ones, so exclude the whole browser if that matters to you.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var runningApps: [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let name = app.localizedName,
                      !state.engine.excludedBundleIDs.contains(id),
                      id != Bundle.main.bundleIdentifier else { return nil }
                return (id, name)
            }
            .sorted { $0.name < $1.name }
    }

    private func displayName(for bundleID: String) -> String {
        exclusionNames[bundleID] ?? bundleID
    }

    // MARK: - Data

    private var dataCard: some View {
        Card(title: "Your data", subtitle: "Everything stays in a local database on this Mac — nothing is uploaded anywhere") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dataSummary)
                        .font(.body.weight(.medium))
                    Text(state.store.url.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([state.store.url])
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button("Reset demo dataset") { state.resetDemoData() }
                Button("Delete all my captured data", role: .destructive) { confirmDeleteLive = true }
                    .confirmationDialog(
                        "Delete every activity record Availeth has captured on this Mac? The demo dataset is kept. This cannot be undone.",
                        isPresented: $confirmDeleteLive
                    ) {
                        Button("Delete my data", role: .destructive) { state.deleteLiveData() }
                    }
                Spacer()
                HStack(spacing: 6) {
                    Text("Rate for estimates:")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("45", value: $state.hourlyRate, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("$/hr").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Never collected

    private var neverCollectedCard: some View {
        Card(title: "What Availeth never collects", subtitle: "True regardless of which capabilities you enable above") {
            let items: [(String, String)] = [
                ("keyboard", "Keystroke content — the characters typed are never recorded, only counted"),
                ("doc.text", "File contents — only a document's name and path, never the bytes inside"),
                ("mic.slash", "Microphone or camera"),
                ("network.slash", "Anything sent off this Mac — Storyline sends frames only to a local model on 127.0.0.1, which never leaves the machine; nothing goes to the internet"),
                ("eye.slash", "Anything at all from excluded apps — their windows are cut from screenshots too"),
            ]
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.1) { icon, text in
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .frame(width: 20)
                            .foregroundStyle(.green)
                        Text(text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Minimal wrapping layout for exclusion chips.
struct FlowLayoutish<Item: Hashable, ItemView: View>: View {
    var items: [Item]
    @ViewBuilder var content: (Item) -> ItemView

    var body: some View {
        // Simple adaptive grid reads well enough for chips and avoids a custom Layout.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}
