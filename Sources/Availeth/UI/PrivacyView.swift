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
    @State private var showAddExclusion = false
    @State private var exclusionSearch = ""
    @State private var hoveredApp: String?

    private var dataSummary: String {
        var parts = ["\(liveSpanCount) activity records"]
        if liveNarrativeCount > 0 { parts.append("\(liveNarrativeCount) storyline notes") }
        if liveScreenshotCount > 0 { parts.append("\(liveScreenshotCount) thumbnails") }
        return parts.joined(separator: " · ") + " captured"
    }

    /// Console hairline used to separate rows within a panel.
    private var hairline: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
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
        .scrollContentBackground(.hidden)
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
                StatusDot(color: state.engine.isPaused ? Theme.amber : (state.engine.isObserving ? Theme.good : Theme.ink3))
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(statusDetail).font(.caption).foregroundStyle(Theme.ink2)
                }
                Spacer()
                if state.engine.isPaused {
                    Button("Resume") { state.engine.resume() }
                        .buttonStyle(.bordered).tint(Theme.accent)
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
                        .buttonStyle(.bordered).tint(Theme.accent)
                }
            }

            hairline

            Toggle(isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    launchAtLoginError = state.setLaunchAtLogin(newValue)
                    launchAtLogin = state.launchAtLoginEnabled
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Start Availeth at login").foregroundStyle(Theme.ink)
                    Text("Keeps discovery running across restarts")
                        .font(.caption).foregroundStyle(Theme.ink2)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            if let launchAtLoginError {
                Text(launchAtLoginError).font(.caption).foregroundStyle(Theme.amber)
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
        Card(title: "Window-title capture", subtitle: "Optional · richer task grouping") {
            HStack(spacing: 12) {
                Image(systemName: axTrusted ? "checkmark.seal.fill" : "seal")
                    .font(.title3)
                    .foregroundStyle(axTrusted ? Theme.good : Theme.ink3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(axTrusted ? "Enabled" : "Not enabled")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text(axTrusted
                         ? "Reads the focused window's title (e.g. “Purchase Orders.xlsx”) — read-only, never controls anything."
                         : "Without this, Availeth only sees which app is frontmost. Grant Accessibility to group time by document.")
                        .font(.caption)
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !axTrusted {
                    Button("Enable…") {
                        AXReader.requestTrust()
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
                }
            }
        }
    }

    // MARK: - Additional capabilities

    @State private var screenRecordingGranted = Permissions.screenRecordingGranted
    @State private var inputMonitoringGranted = Permissions.inputMonitoringGranted

    private var capabilitiesCard: some View {
        Card(title: "Additional capture", subtitle: "Each can be switched off · shown in the Logs tab") {
            // Keyboard & mouse — a single on/off (on = the richest signal, which
            // reads field labels but never the keys you press).
            captureRow(
                icon: "keyboard",
                title: "Keyboard & mouse activity",
                description: "Which shortcuts and fields a task uses — never the keys you type.",
                on: Binding(
                    get: { state.engine.telemetryMode != .off },
                    set: { state.engine.telemetryMode = $0 ? .deep : .off }
                )
            ) {
                if state.engine.telemetryMode != .off && !inputMonitoringGranted {
                    permissionWarning("Needs Input Monitoring — grant it, then relaunch.",
                                      grant: { requestInputMonitoring() })
                } else if state.engine.telemetryMode != .off && !axTrusted {
                    subNote("Field names also need Window-title capture, enabled above.")
                }
            }

            hairline

            // Screen capture — a single on/off. On always uses the local Storyline
            // model at full detail (no sub-choice).
            captureRow(
                icon: "camera.viewfinder",
                title: "Screen capture",
                description: "A local model reads each new screen, then deletes the image — only text is kept.",
                on: Binding(
                    get: { state.engine.screenshotMode == .storyline },
                    set: { on in
                        if on {
                            state.engine.captureDepth = .detailed   // always detailed — no user choice
                            state.engine.screenshotMode = .storyline
                        } else {
                            state.engine.screenshotMode = .off
                        }
                    }
                )
            ) {
                if state.engine.screenshotMode == .storyline {
                    if !screenRecordingGranted {
                        permissionWarning("Needs Screen Recording. Granted it already? macOS applies it after a relaunch.",
                                          grant: {
                                              Permissions.requestScreenRecording()
                                              openSettings("com.apple.preference.security?Privacy_ScreenCapture")
                                          }, relaunch: true)
                    }
                    HStack(spacing: 8) {
                        StatusDot(color: state.engine.interpreterReady ? Theme.good : Theme.amber, halo: false, size: 7)
                        Text(state.engine.interpreterReady
                             ? "Local model ready: \(state.engine.sceneInterpreterName)"
                             : "Local model not reachable — start Ollama and pull a vision model (e.g. qwen2.5vl:7b).")
                            .font(.caption).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 33)
                }
            }

            hairline

            // File tracking — already a simple on/off.
            captureRow(
                icon: "doc.text.magnifyingglass",
                title: "File tracking (identity only)",
                description: "Which document is open — its name and path, never the contents.",
                on: Binding(get: { state.engine.fileTrackingEnabled }, set: { state.engine.fileTrackingEnabled = $0 })
            ) {
                if state.engine.fileTrackingEnabled && !axTrusted {
                    permissionWarning("Needs Window-title capture (Accessibility) to identify files.",
                                      grant: {
                                          AXReader.requestTrust()
                                          openSettings("com.apple.preference.security?Privacy_Accessibility")
                                      })
                }
            }

            hairline

            // Website identity — the host of a browser tab, so the task can show
            // the site's own icon. Icons come from the browser's cache on this
            // Mac; nothing is fetched from the internet.
            captureRow(
                icon: "globe",
                title: "Website identity (icons only)",
                description: "Only the site's host name (e.g. onlinebanking.aib.ie) — never the full address or the page — so tasks show the site's own icon, read from your browser's icon cache on this Mac.",
                on: Binding(get: { state.engine.siteIdentityEnabled }, set: { state.engine.siteIdentityEnabled = $0 })
            ) {
                if state.engine.siteIdentityEnabled && !axTrusted {
                    permissionWarning("Needs Window-title capture (Accessibility) to read the tab address.",
                                      grant: {
                                          AXReader.requestTrust()
                                          openSettings("com.apple.preference.security?Privacy_Accessibility")
                                      })
                } else if state.engine.siteIdentityEnabled {
                    subNote("Chrome, Arc, Brave, Edge and Firefox need nothing extra. Safari's icons would need Full Disk Access, which Availeth never asks for. Nothing is fetched from the internet.")
                }
            }

            hairline

            HStack {
                Button {
                    state.welcomeRequested = true
                } label: {
                    Label("Setup guide & permissions", systemImage: "sparkles")
                }
                .controlSize(.small)
                Spacer()
            }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            screenRecordingGranted = Permissions.screenRecordingGranted
            inputMonitoringGranted = Permissions.inputMonitoringGranted
        }
        .onAppear { if state.engine.screenshotMode == .storyline { state.engine.refreshInterpreterStatus() } }
    }

    /// One capability row: icon + title + one-line description + an on/off switch,
    /// with optional permission/consent detail shown below only while it's on.
    @ViewBuilder
    private func captureRow<Extra: View>(icon: String, title: String, description: String, on: Binding<Bool>, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 11) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 22).foregroundStyle(Theme.ink2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(description).font(.caption).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
            }
            extra()
        }
    }

    /// Amber permission warning with a Grant (and optional Relaunch) button.
    @ViewBuilder
    private func permissionWarning(_ text: String, grant: @escaping () -> Void, relaunch: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.amber)
            Text(text).font(.caption).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            Button("Grant…", action: grant).controlSize(.small)
            if relaunch {
                Button("Relaunch", systemImage: "arrow.clockwise") { Permissions.relaunchApp() }.controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 33)
    }

    @ViewBuilder
    private func subNote(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 33)
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
        Card(title: "Excluded apps", subtitle: "Never recorded while in front") {
            VStack(alignment: .leading, spacing: 12) {
                if state.engine.excludedBundleIDs.isEmpty {
                    Text("Nothing is excluded — Availeth records every app. Add one below to leave an app out.")
                        .font(.caption).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    FlowLayoutish(items: state.engine.excludedBundleIDs.sorted()) { bundleID in
                        exclusionChip(bundleID)
                    }
                }

                Button {
                    showAddExclusion = true
                } label: {
                    Label("Exclude an app…", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.accent)
                .popover(isPresented: $showAddExclusion, arrowEdge: .bottom) { addExclusionPopover }

                Text("Exclusions are per app. Private browser windows look the same as normal ones, so exclude the whole browser if that matters.")
                    .font(.caption2)
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A removable chip showing the excluded app's real icon and name.
    private func exclusionChip(_ bundleID: String) -> some View {
        HStack(spacing: 6) {
            if let icon = appIcon(for: bundleID) {
                Image(nsImage: icon).resizable().frame(width: 15, height: 15)
            }
            Text(displayName(for: bundleID))
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Button {
                state.engine.excludedBundleIDs.remove(bundleID)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop excluding \(displayName(for: bundleID))")
        }
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.panelHi))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    /// Searchable picker of running apps, each with its icon.
    private var addExclusionPopover: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                TextField("Search apps", text: $exclusionSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            Rectangle().fill(Theme.line).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    let apps = filteredRunningApps
                    if apps.isEmpty {
                        Text(exclusionSearch.isEmpty ? "No other apps running." : "No matches.")
                            .font(.caption).foregroundStyle(Theme.ink3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 11).padding(.vertical, 12)
                    } else {
                        ForEach(apps, id: \.bundleID) { app in
                            Button {
                                state.engine.excludedBundleIDs.insert(app.bundleID)
                                showAddExclusion = false
                                exclusionSearch = ""
                            } label: {
                                HStack(spacing: 9) {
                                    if let icon = appIcon(for: app.bundleID) {
                                        Image(nsImage: icon).resizable().frame(width: 17, height: 17)
                                    }
                                    Text(app.name).font(.system(size: 13)).foregroundStyle(Theme.ink)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(hoveredApp == app.bundleID ? Theme.accentDim : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hoveredApp = $0 ? app.bundleID : (hoveredApp == app.bundleID ? nil : hoveredApp) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 260)
        }
        .frame(width: 280)
        .background(Theme.panel)
    }

    private var filteredRunningApps: [(bundleID: String, name: String)] {
        let q = exclusionSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return runningApps.filter { q.isEmpty || $0.name.lowercased().contains(q) }
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

    /// The app's Finder icon for a bundle ID (nil if the app isn't installed).
    private func appIcon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 17, height: 17)
        return icon
    }

    // MARK: - Data

    private var dataCard: some View {
        Card(title: "Your data", subtitle: "Stored locally · never uploaded") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dataSummary)
                        .font(.system(size: 13, weight: .medium)).numeric()
                        .foregroundStyle(Theme.ink)
                    Text(state.store.url.path)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([state.store.url])
                }
            }

            hairline

            HStack(spacing: 10) {
                Button("Reset demo dataset") { state.resetDemoData() }
                Button("Delete all my captured data", role: .destructive) { confirmDeleteLive = true }
                    .tint(Theme.danger)
                    .confirmationDialog(
                        "Delete every activity record Availeth has captured on this Mac? The demo dataset is kept. This cannot be undone.",
                        isPresented: $confirmDeleteLive
                    ) {
                        Button("Delete my data", role: .destructive) { state.deleteLiveData() }
                    }
                Spacer()
                HStack(spacing: 6) {
                    Text("Rate for estimates:")
                        .font(.caption).foregroundStyle(Theme.ink2)
                    TextField("45", value: $state.hourlyRate, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .numeric()
                        .frame(width: 60)
                    Text("$/hr").font(.caption).foregroundStyle(Theme.ink2)
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
                            .foregroundStyle(Theme.good)
                        Text(text)
                            .font(.callout)
                            .foregroundStyle(Theme.ink2)
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
