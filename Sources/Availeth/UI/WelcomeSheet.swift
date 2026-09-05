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
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    promise
                    permissionsSection
                    capabilitiesSection
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 680)
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to Availeth")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Discovers repetitive work worth automating — transparently, and on this Mac only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var promise: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([
                ("lock.laptopcomputer", "Everything stays on this Mac. Nothing is uploaded to the internet."),
                ("eye", "You can see everything captured — including screenshots and AI descriptions — in the Logs tab."),
                ("hand.raised", "You choose what's on below, pause anytime, and delete all data in one click."),
            ], id: \.1) { icon, text in
                Label {
                    Text(text).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: icon).foregroundStyle(.indigo)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions").font(.headline)
            Text("Availeth asks for these up front. Each is optional and unlocks a different level of detail.")
                .font(.caption).foregroundStyle(.secondary)

            permissionRow(
                icon: "macwindow", title: "Accessibility",
                detail: "Read window titles and field names, so time is grouped by document and task. Read-only.",
                granted: axTrusted
            ) {
                AXReader.requestTrust()
                openSettings("Privacy_Accessibility")
            }
            permissionRow(
                icon: "camera.viewfinder", title: "Screen Recording",
                detail: "Needed for screenshots and the local-AI storyline. You'll relaunch once after granting.",
                granted: screenGranted
            ) {
                Permissions.requestScreenRecording()
                openSettings("Privacy_ScreenCapture")
            }
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

    private func permissionRow(icon: String, title: String, detail: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Grant…", action: request)
                    .buttonStyle(.borderedProminent).tint(.indigo).controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Capabilities

    private var capabilitiesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What to capture").font(.headline)

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keyboard & mouse activity").font(.callout.weight(.medium))
                    Text("Which shortcuts you use and how much typing a task takes — never the actual keys.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker("", selection: Binding(get: { state.engine.telemetryMode }, set: { state.engine.telemetryMode = $0 })) {
                    ForEach(InputTelemetryMode.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 190)
            }

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen capture").font(.callout.weight(.medium))
                    Text("Thumbnails (blurred) or Storyline (local AI describes each frame).").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: Binding(get: { state.engine.screenshotMode }, set: { state.engine.screenshotMode = $0 })) {
                    ForEach(ScreenshotMode.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 210)
            }

            if state.engine.screenshotMode == .storyline {
                HStack(spacing: 8) {
                    Circle().fill(state.engine.interpreterReady ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(state.engine.interpreterReady
                         ? "Local model ready: \(state.engine.sceneInterpreterName)"
                         : "Storyline needs Ollama running with a vision model (e.g. qwen2.5vl:7b).")
                        .font(.caption).foregroundStyle(.secondary)
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
            .buttonStyle(.borderedProminent).tint(.indigo).controlSize(.large)
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
