import AppKit

/// macOS pieces that come to the front but are not apps anyone works in — the
/// lock screen, the Wi-Fi sign-in sheet, password and Touch ID prompts, system
/// alerts, the Dock and Spotlight. They never become spans: there is nothing
/// to learn from them and they would only pad the charts.
enum SystemProcesses {
    /// Known agents by bundle id (what the charts had started to show, plus the
    /// usual suspects).
    static let bundleIDs: Set<String> = [
        "com.apple.loginwindow", "com.apple.CaptiveNetworkAssistant", "com.apple.UserNotificationCenter",
        "com.apple.LocalAuthentication.UIAgent", "com.apple.SecurityAgent", "com.apple.accessibility.universalAccessAuthWarn",
        "com.apple.coreservices.uiagent", "com.apple.ScreenSaver.Engine", "com.apple.dock", "com.apple.systemuiserver",
        "com.apple.Spotlight", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.Siri",
        "com.apple.AirPlayUIAgent", "com.apple.WindowManager", "com.apple.wallpaper.agent", "com.apple.TextInputMenuAgent",
        "com.apple.printcenter", "com.apple.PowerChime", "com.apple.UIKitSystem", "com.apple.ScreenContinuity",
        "com.apple.screencaptureui", "com.apple.SoftwareUpdate", "com.apple.UnmountAssistantAgent", "com.apple.KeyboardSetupAssistant",
    ]

    /// Their process names as they were recorded, for cleaning up narratives.
    static let appNames: Set<String> = [
        "loginwindow", "Captive Network Assistant", "UserNotificationCenter", "coreautha", "SecurityAgent",
        "universalAccessAuthWarn", "CoreServicesUIAgent", "ScreenSaverEngine", "Dock", "SystemUIServer", "Spotlight",
        "Control Center", "Notification Center", "Siri", "AirPlayUIAgent", "WindowManager", "Wallpaper", "TextInputMenuAgent",
        "Print Center", "PowerChime", "Screenshot", "Software Update",
    ]

    /// The explicit list, plus any Apple process that isn't a regular (Dock)
    /// app — agents and helpers use the accessory/prohibited policies. Third-
    /// party menu-bar apps (a dictation tool, say) are left alone: people do
    /// work in those.
    static func isSystem(bundleID: String, activationPolicy: NSApplication.ActivationPolicy?) -> Bool {
        if bundleIDs.contains(bundleID) { return true }
        if let policy = activationPolicy, policy != .regular, bundleID.hasPrefix("com.apple.") { return true }
        return false
    }

    static func isSystem(_ app: NSRunningApplication) -> Bool {
        isSystem(bundleID: app.bundleIdentifier ?? "", activationPolicy: app.activationPolicy)
    }

    /// Strips the invisible direction/format marks some apps put in their
    /// names ("\u{200E}WhatsApp"), which otherwise show as a stray space and
    /// split the app from itself.
    static func cleanAppName(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.properties.generalCategory != .format }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
