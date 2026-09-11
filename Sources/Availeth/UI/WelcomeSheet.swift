import AppKit
import SwiftUI

/// First-run onboarding: explains what Availeth does, requests every permission
/// up front, and lets the user choose what to enable — all in one place, so the
/// permissions aren't buried in a settings tab.
struct WelcomeSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    static let onboardedKey = "availeth.hasOnboarded"

    @State private var axTrusted = AXReader.isTrusted
    @State private var screenGranted = Permissions.screenRecordingGranted
    @State private var inputGranted = Permissions.inputMonitoringGranted

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    promise
                    permissionsSection
                    capabilitiesSection
                }
                .padding(24)
            }
            .scrollContentBackground(.hidden)
            Rectangle().fill(Theme.line).frame(height: 1)
            footer
        }
        .frame(width: 560, height: 680)
        .appCanvas()
        .tint(Theme.accent)
        .task {
            while !Task.isCancelled {
                axTrusted = AXReader.isTrusted
                screenGranted = Permissions.screenRecordingGranted
                inputGranted = Permissions.inputMonitoringGranted
                if state.engine.screenshotMode == .storyline { state.engine.refreshInterpreterStatus() }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            LogoMark(size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome to Availeth")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("Discovers repetitive work worth automating — transparently, and on this Mac only.")
                    .font(.callout)
                    .foregroundStyle(Theme.ink2)
            }
            Spacer()
        }
        .padding(20)
    }

    private var promise: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([
                ("lock.laptopcomputer", "Everything stays on this Mac. Nothing is uploaded to the internet."),
                ("eye", "You can see everything captured — including screenshots and AI descriptions — in the Logs tab."),
                ("hand.raised", "You choose what's on below, pause anytime, and delete all data in one click."),
            ], id: \.1) { icon, text in
                Label {
                    Text(text).font(.callout).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: icon).foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSkin()
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Panel(title: "Permissions", caption: "optional") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Availeth asks for these up front. Each is optional and unlocks a different level of detail.")
                    .font(.caption).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    permissionRow(
                        icon: "macwindow", title: "Accessibility",
                        detail: "Read window titles and field names, so time is grouped by document and task. Read-only.",
                        granted: axTrusted
                    ) {
                        AXReader.requestTrust()
                        openSettings("Privacy_Accessibility")
                    }
                    Rectangle().fill(Theme.line).frame(height: 1)
                    permissionRow(
                        icon: "camera.viewfinder", title: "Screen Recording",
                        detail: "Needed for screenshots and the local-AI storyline. macOS only applies this one after a relaunch — grant it, then click Relaunch.",
                        granted: screenGranted,
                        needsRelaunch: true
                    ) {
                        Permissions.requestScreenRecording()
                        openSettings("Privacy_ScreenCapture")
                    }
                    Rectangle().fill(Theme.line).frame(height: 1)
                    permissionRow(
                        icon: "keyboard", title: "Input Monitoring",
                        detail: "Count keystrokes and clicks and detect shortcuts — never the characters you type. Grant, then relaunch.",
                        granted: inputGranted
                    ) {
                        _ = Permissions.requestInputMonitoring()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { openSettings("Privacy_ListenEvent") }
                    }
                }
            }
        }
    }

    private func permissionRow(icon: String, title: String, detail: String, granted: Bool, needsRelaunch: Bool = false, request: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(Theme.ink2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(Theme.ink)
                Text(detail).font(.caption).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.good)
                    .labelStyle(.titleAndIcon)
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Grant…", action: request)
                        .buttonStyle(.bordered).tint(Theme.accent).controlSize(.small)
                    if needsRelaunch {
                        // The grant is invisible to this process until restart —
                        // make the required relaunch one click, not a mystery.
                        Button("Relaunch to apply", systemImage: "arrow.clockwise") { Permissions.relaunchApp() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Capabilities

    private var capabilitiesSection: some View {
        Panel(title: "What to capture") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keyboard & mouse activity").font(.callout.weight(.medium)).foregroundStyle(Theme.ink)
                        Text("Which shortcuts you use and how much typing a task takes — never the actual keys.")
                            .font(.caption).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    SegControl(
                        items: InputTelemetryMode.allCases.map { ($0.title, $0) },
                        selection: Binding(get: { state.engine.telemetryMode },
                                           set: { state.engine.telemetryMode = $0 })
                    )
                }

                Rectangle().fill(Theme.line).frame(height: 1)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen capture").font(.callout.weight(.medium)).foregroundStyle(Theme.ink)
                        Text("Thumbnails (blurred) or Storyline (local AI describes each frame).")
                            .font(.caption).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    SegControl(
                        items: ScreenshotMode.allCases.map { ($0.title, $0) },
                        selection: Binding(get: { state.engine.screenshotMode },
                                           set: { state.engine.screenshotMode = $0 })
                    )
                }

                if state.engine.screenshotMode == .storyline {
                    HStack(spacing: 8) {
                        StatusDot(color: state.engine.interpreterReady ? Theme.good : Theme.amber, halo: false)
                        Text(state.engine.interpreterReady
                             ? "Local model ready: \(state.engine.sceneInterpreterName)"
                             : "Storyline needs Ollama running with a vision model (e.g. qwen2.5vl:7b).")
                            .font(.caption).foregroundStyle(Theme.ink2)
                    }
                }

                Rectangle().fill(Theme.line).frame(height: 1)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Website identity (icons only)").font(.callout.weight(.medium)).foregroundStyle(Theme.ink)
                        Text("Only a browser tab's host name, so tasks show the site's own icon \u{2014} read from your browser's cache on this Mac, never the internet.")
                            .font(.caption).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { state.engine.siteIdentityEnabled }, set: { state.engine.siteIdentityEnabled = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Not now") { finish() }
            Spacer()
            Button {
                finish()
            } label: {
                Text("Start Discovery").frame(minWidth: 120)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
        }
        .padding(20)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        if !state.engine.isObserving { state.engine.start() }
        dismiss()
    }

    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
