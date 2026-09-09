import AppKit
import SwiftUI

/// Holds the SwiftUI `openWindow` action so AppKit (the AppDelegate) can reopen
/// the dashboard when the user clicks the Dock icon after closing the window.
/// `OpenWindowAction` is app-scoped, so a reference captured once stays valid
/// even while no window is open.
final class WindowOpener {
    static let shared = WindowOpener()
    var open: (() -> Void)?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular Dock app (not a menu-bar-only accessory): shows in the Dock,
        // and right-click → Quit is available there.
        NSApp.setActivationPolicy(.regular)
        applyDockIcon()
        AppState.shared.applyAppearance()   // honor the saved Light/Dark choice (default Light)
        AppState.shared.bootstrap()
        NSApp.activate()
    }

    /// Sets the Dock tile from the bundled AppIcon.icns. The bundle's
    /// CFBundleIconFile already does this at launch, but LaunchServices caches
    /// icons aggressively for an app that stays resident — setting it explicitly
    /// makes a new icon appear immediately without a Dock/cache flush.
    private func applyDockIcon() {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Clicking the window's red X keeps Availeth running in the background
        // (Dock icon stays) instead of quitting. Quit via right-click → Quit.
        false
    }

    /// Clicking the Dock icon with no window open reopens the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowOpener.shared.open?() }
        NSApp.activate()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Persist the in-progress span — otherwise the last (often longest)
        // stretch of work is lost on every quit, logout, and shutdown.
        AppState.shared.engine.shutdown()
        OllamaService.shared.shutdown()   // stop our own copy; a customer's own service is left alone
    }
}

@main
struct AvailethApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("Availeth", id: "dashboard") {
            DashboardRoot()
                .environmentObject(state)
        }
        .defaultSize(width: 1200, height: 780)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            Image(systemName: "chart.bar.doc.horizontal")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Wraps the dashboard so it can capture `openWindow` for Dock-reopen.
private struct DashboardRoot: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        DashboardView()
            .frame(minWidth: 980, minHeight: 640)
            .onAppear { WindowOpener.shared.open = { openWindow(id: "dashboard") } }
    }
}
