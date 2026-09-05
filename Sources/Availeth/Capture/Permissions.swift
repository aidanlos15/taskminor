import CoreGraphics
import Foundation

/// Preflight/request helpers for the two additional TCC permissions the
/// enrichment capabilities need. Each is separate from Accessibility and from
/// each other — the user grants only what they turn on.
enum Permissions {

    // MARK: - Screen Recording (for screenshots)

    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Fires the system Screen Recording prompt. Returns the immediate result;
    /// on first grant macOS typically requires an app relaunch to take effect.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Input Monitoring (for keystroke/click COUNTS only)

    // Use the CoreGraphics event-access APIs (CGPreflight/CGRequestListenEventAccess).
    // These are the canonical calls for event monitoring: they register the app
    // in the Input Monitoring list AND raise the system prompt. (The IOKit HID
    // request API frequently does neither for a plain event-monitoring client,
    // which is why the list showed "No Items".)
    static var inputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    /// Fires the system Input Monitoring prompt and registers the app in the
    /// Input Monitoring list. Returns the immediate result; a relaunch is
    /// usually needed after first grant.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }
}
