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

            VStack(alignment: .leading, spacing: 4) {
                Text(Format.duration(state.engine.observedTodaySeconds))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("observed today")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            topAppsToday

            Divider()

            controlButtons
        }
        .padding(16)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            LogoMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Availeth").font(.headline)
                statusLine
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if state.engine.isPaused {
            Label("Paused", systemImage: "pause.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if state.engine.isObserving {
            HStack(spacing: 5) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text(state.engine.currentAppName.map { "Observing \($0)" } ?? "Discovery active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Label("Stopped", systemImage: "stop.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var topAppsToday: some View {
        // Cached in AppState — no store queries during rendering.
        let totals = state.todayTopApps
        return Group {
            if totals.isEmpty {
                Text("No activity captured yet today.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(totals) { app in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(AppPalette.color(for: app.appName))
                                .frame(width: 8, height: 8)
                            Text(app.appName)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(Format.duration(app.duration))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.indigo)

            if state.engine.isPaused {
                Button {
                    state.engine.resume()
                } label: {
                    Label("Resume Discovery", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
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
            } else {
                Button {
                    state.engine.start()
                } label: {
                    Label("Start Discovery", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }

            HStack {
                Text("No keystrokes · No screenshots")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }
}

/// The Availeth logo mark used across the app.
struct LogoMark: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(red: 0.42, green: 0.36, blue: 0.98), Color(red: 0.68, green: 0.36, blue: 0.95)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            .overlay {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
    }
}
