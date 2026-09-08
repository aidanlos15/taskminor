import SwiftUI

/// The panel shown when clicking the menu bar icon: live status, today's
/// observed time, top apps, and pause controls — the transparency surface.
struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(alignment: .leading, spacing: 5) {
                Text(Format.duration(state.engine.observedTodaySeconds))
                    .font(.system(size: 30, weight: .bold)).numeric()
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text("observed today").microLabel()
            }

            topAppsToday

            Rectangle().fill(Theme.line).frame(height: 1)

            controlButtons
        }
        .padding(16)
        .frame(width: 300)
        .background(Theme.bg)
        .tint(Theme.accent)
    }

    private var header: some View {
        HStack(spacing: 10) {
            LogoMark(size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Wordmark(size: 14)
                statusLine
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if state.engine.isPaused {
            HStack(spacing: 6) {
                StatusDot(color: Theme.amber, halo: false)
                Text("Paused")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink2)
            }
        } else if state.engine.isObserving {
            HStack(spacing: 6) {
                StatusDot(color: Theme.good)
                Text(state.engine.currentAppName.map { "Observing \($0)" } ?? "Discovery active")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: 6) {
                StatusDot(color: Theme.ink3, halo: false)
                Text("Stopped")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink2)
            }
        }
    }

    private var topAppsToday: some View {
        // Cached in AppState — no store queries during rendering.
        let totals = state.todayTopApps
        return Group {
            if totals.isEmpty {
                Text("No activity captured yet today.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(totals) { app in
                        HStack(spacing: 9) {
                            Circle()
                                .fill(AppPalette.color(for: app.appName))
                                .frame(width: 7, height: 7)
                            Text(app.appName)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Spacer()
                            Text(Format.duration(app.duration))
                                .font(.system(size: 11)).numeric()
                                .foregroundStyle(Theme.ink3)
                        }
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelSkin()
            }
        }
    }

    private var controlButtons: some View {
        VStack(spacing: 8) {
            Button {
                dismiss()
                openWindow(id: "dashboard")
                NSApp.activate()
            } label: {
                Label("Open Dashboard", systemImage: "rectangle.grid.2x2")
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(Theme.bg)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent))
            }
            .buttonStyle(.plain)

            if state.engine.isPaused {
                Button {
                    state.engine.resume()
                } label: {
                    Label("Resume Discovery", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .tint(Theme.accent)
            } else if state.engine.isObserving {
                HStack(spacing: 8) {
                    Button("Pause 15m") { state.engine.pause(for: 15 * 60) }
                        .frame(maxWidth: .infinity)
                    Button("Pause 1h") { state.engine.pause(for: 3600) }
                        .frame(maxWidth: .infinity)
                    Button("Rest of day") { state.engine.pauseUntilTomorrow() }
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(Theme.ink2)
            } else {
                Button {
                    state.engine.start()
                } label: {
                    Label("Start Discovery", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .tint(Theme.accent)
            }

            HStack {
                Text("No keystrokes · No screenshots")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ink3)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(Theme.ink2)
            }
        }
    }
}
