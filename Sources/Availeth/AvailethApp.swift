import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.bootstrap()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep observing from the menu bar when the dashboard closes.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Persist the in-progress span — otherwise the last (often longest)
        // stretch of work is lost on every quit, logout, and shutdown.
        AppState.shared.engine.shutdown()
    }
}

@main
struct AvailethApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("Availeth", id: "dashboard") {
            DashboardView()
                .environmentObject(state)
                .frame(minWidth: 980, minHeight: 640)
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
