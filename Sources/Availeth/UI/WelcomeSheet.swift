import AppKit
import SwiftUI

/// First-run onboarding: explains what Availeth does, requests every permission
/// up front, and lets the user choose what to enable — all in one place, so the
/// permissions aren't buried in a settings tab.
struct WelcomeSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    static let onboardedKey = "availeth.hasOnboarded"
    /// Set the first time the three system prompts are fired, so they are raised
    /// once and never again on later openings of this sheet.
    static let promptedKey = "availeth.hasRequestedPermissions"

    @State private var axTrusted = AXReader.isTrusted
    @State private var screenGranted = Permissions.screenRecordingGranted
    @State private var inputGranted = Permissions.inputMonitoringGranted
    /// Which system prompt is on screen right now, for the "asking now" line.
    @State private var requesting: String?

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
        .task { await requestAllPermissionsOnce() }
        .task {
            while !Task.isCancelled {
                axTrusted = AXReader.isTrusted
                screenGranted = Permissions.screenRecordingGranted
                inputGranted = Permissions.inputMonitoringGranted
                state.engine.refreshInterpreterStatus()
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
                Text("Availeth asks for all three now. Each is optional and unlocks a different level of detail. macOS shows one dialog at a time.")
                    .font(.caption).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                if let asking = requesting {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Asking macOS for \(asking)…").font(.caption.weight(.medium)).foregroundStyle(Theme.ink)
                    }
                    .padding(.vertical, 2)
                }

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
                        detail: "Needed for screen capture. macOS applies this one only after a relaunch. Grant it, then click Relaunch.",
                        granted: screenGranted,
                        needsRelaunch: true
                    ) {
                        Permissions.requestScreenRecording()
                        openSettings("Privacy_ScreenCapture")
                    }
                    Rectangle().fill(Theme.line).frame(height: 1)
                    permissionRow(
                        icon: "keyboard", title: "Input Monitoring",
                        detail: "Counts keystrokes and clicks, and spots shortcuts. Never the characters you type. Grant, then relaunch.",
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

    /// On the first ever launch, raise all three system prompts in turn rather
    /// than waiting for the user to find three separate Grant buttons.
    ///
    /// Order matters. Screen Recording and Input Monitoring show a dialog with
    /// Allow and Deny, answered without leaving Availeth. Accessibility's dialog
    /// only offers "Open System Settings", so it takes the user out of the app
    /// for as long as it takes them to find the switch. It therefore goes LAST:
    /// anything fired after it lands on a screen the user is no longer looking
    /// at, and macOS raises each prompt only once per app, so a missed prompt is
    /// missed permanently. (Measured on a clean install with fixed 2 s gaps:
    /// Accessibility was granted 8 s after firing, by which time the other two
    /// had already fired into an empty screen and neither registered.)
    ///
    /// Each step waits for its answer rather than sleeping a fixed interval.
    private func requestAllPermissionsOnce() async {
        guard !UserDefaults.standard.bool(forKey: Self.promptedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.promptedKey)
        try? await Task.sleep(for: .seconds(1.2))   // let the sheet be read first

        if !Permissions.screenRecordingGranted {
            requesting = "Screen Recording"
            Permissions.requestScreenRecording()
            await waitForAnswer(seconds: 45) { Permissions.screenRecordingGranted }
        }
        if !Permissions.inputMonitoringGranted {
            requesting = "Input Monitoring"
            Permissions.requestInputMonitoring()
            await waitForAnswer(seconds: 45) { Permissions.inputMonitoringGranted }
        }
        if !AXReader.isTrusted {
            requesting = "Accessibility"
            AXReader.requestTrust()
            await waitForAnswer(seconds: 180) { AXReader.isTrusted }
        }
        requesting = nil
    }

    /// Polls twice a second until the permission is granted or the budget runs
    /// out. A denial cannot be observed directly, so the timeout is what moves
    /// the sequence on; it is generous because granting Accessibility means a
    /// trip to System Settings.
    private func waitForAnswer(seconds: Int, _ granted: @escaping () -> Bool) async {
        for _ in 0..<(seconds * 2) {
            if granted() || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func finish() {
        // Only count the user as onboarded once something was actually granted.
        // Marking it done regardless meant one stray click on the very first
        // launch permanently cost the app every capability, with no second ask
        // and nothing on screen to say so.
        let anyGranted = AXReader.isTrusted
            || Permissions.screenRecordingGranted
            || Permissions.inputMonitoringGranted
        if anyGranted {
            UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        }
        if !state.engine.isObserving { state.engine.start() }
        // Leaving the intro means leaving the sample data behind.
        state.showDemo = false
        dismiss()
    }

    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
