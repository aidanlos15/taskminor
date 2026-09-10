import AppKit
import SwiftUI

/// One thing Availeth needs in order to see something, and whether it has it.
struct CoverageFact: Identifiable, Equatable {
    /// Stable key so lists do not re-shuffle between refreshes.
    let id: String
    /// What the fact is, in a couple of words.
    let label: String
    /// Whether it is working right now.
    let ok: Bool
    /// The current state, in one short line.
    let detail: String
}

/// Something that is missing, with the words to say it and where to fix it.
struct CoverageGap: Identifiable, Equatable {
    enum Fix: Equatable {
        /// Open the Privacy tab.
        case privacy
        /// Open the Privacy tab and jump to the Local AI panel.
        case localAI
        /// Ask macOS for Accessibility.
        case accessibility
        /// Ask macOS for Screen Recording.
        case screenRecording
        /// Ask macOS for Input Monitoring.
        case inputMonitoring
    }

    let id: String
    /// The headline. Short sentence, no full stop.
    let title: String
    /// One line of why it matters.
    let detail: String
    /// The button label.
    let action: String
    let fix: Fix
}

/// What Availeth can and cannot see, in one place.
///
/// The app used to tell people to turn on screen capture when screen capture was
/// already on and the vision model was simply not installed. Every message about
/// thin data now comes from here, so they all say the same true thing.
struct CoverageStatus: Equatable {
    /// Accessibility is granted, so window titles can be read.
    var windowTitlesReadable = false
    /// Interaction telemetry setting.
    var telemetryMode: InputTelemetryMode = .off
    /// Input Monitoring is granted.
    var inputMonitoringGranted = false
    /// Screen capture setting.
    var screenshotMode: ScreenshotMode = .off
    /// Screen Recording is granted.
    var screenRecordingGranted = false
    /// The local vision model is installed and answering.
    var visionModelReady = false
    /// The local text model is installed and answering.
    var textModelReady = false
    /// The name of the vision model, for the Local AI panel.
    var visionModelName = "a vision model"
    /// The name of the text model.
    var textModelName = "a text model"

    // MARK: - Derived

    /// Screen capture is set to something other than off.
    var screenCaptureOn: Bool { screenshotMode != .off }

    /// Screen capture is on, permitted, and (in storyline mode) has its model.
    /// This is the only state in which written screen detail can appear.
    var screenReadingWorking: Bool {
        guard screenCaptureOn, screenRecordingGranted else { return false }
        return screenshotMode == .storyline && visionModelReady
    }

    // MARK: - The six facts

    var facts: [CoverageFact] {
        [
            CoverageFact(
                id: "titles",
                label: "Window titles",
                ok: windowTitlesReadable,
                detail: windowTitlesReadable
                    ? "Readable"
                    : "Not readable. Accessibility is not granted."),
            CoverageFact(
                id: "telemetry",
                label: "Typing and clicks",
                ok: telemetryMode != .off && inputMonitoringGranted,
                detail: telemetryDetail),
            CoverageFact(
                id: "capture",
                label: "Screen capture",
                ok: screenCaptureOn,
                detail: screenshotMode == .off ? "Off" : "Set to \(screenshotMode.title)"),
            CoverageFact(
                id: "recording",
                label: "Screen Recording permission",
                ok: screenRecordingGranted,
                detail: screenRecordingGranted ? "Granted" : "Not granted"),
            CoverageFact(
                id: "vision",
                label: "Vision model",
                ok: visionModelReady,
                detail: visionModelReady ? "Installed: \(visionModelName)" : "Not installed"),
            CoverageFact(
                id: "text",
                label: "Text model",
                ok: textModelReady,
                detail: textModelReady ? "Installed: \(textModelName)" : "Not installed"),
        ]
    }

    private var telemetryDetail: String {
        if telemetryMode == .off { return "Off" }
        if !inputMonitoringGranted { return "On, but Input Monitoring is not granted." }
        return "On, set to \(telemetryMode.title)"
    }

    // MARK: - Gaps

    /// Everything that is missing, most blocking first. A setting the person
    /// deliberately turned off is not a gap; only a setting that is on and not
    /// working, or a piece the app cannot do its job without.
    var gaps: [CoverageGap] {
        var out: [CoverageGap] = []

        if screenCaptureOn && !screenRecordingGranted {
            out.append(CoverageGap(
                id: "recording",
                title: "Screen Recording permission is missing",
                detail: "Screen capture is on, but macOS is not letting Availeth read the screen. Nothing on screen is being recorded.",
                action: "Grant",
                fix: .screenRecording))
        }
        if screenshotMode == .storyline && !visionModelReady {
            out.append(CoverageGap(
                id: "vision",
                title: "Screen reading is on but no vision model is installed",
                detail: "Every screen is being skipped, so tasks and workflows have no screen detail. The model is a one-time download.",
                action: "Install",
                fix: .localAI))
        }
        if !windowTitlesReadable {
            out.append(CoverageGap(
                id: "titles",
                title: "Window titles cannot be read (Accessibility not granted)",
                detail: "Availeth records app names and nothing else, so separate pieces of work look the same.",
                action: "Grant",
                fix: .accessibility))
        }
        if telemetryMode != .off && !inputMonitoringGranted {
            out.append(CoverageGap(
                id: "input",
                title: "Typing and clicks are on but Input Monitoring is missing",
                detail: "Availeth cannot tell busy work from reading, so active time is under-counted.",
                action: "Grant",
                fix: .inputMonitoring))
        }
        if !textModelReady {
            out.append(CoverageGap(
                id: "text",
                title: "No text model is installed",
                detail: "Task stories are not written. The rest of the app still works.",
                action: "Install",
                fix: .localAI))
        }
        return out
    }

    // MARK: - Wording reused by the empty states

    /// Why a task or a workflow has no screen detail. One sentence, true for the
    /// state the app is actually in.
    var noScreenDetailReason: String {
        if !screenCaptureOn {
            return "Screen capture is off, so nothing on screen was recorded. Turn it on in the Privacy tab."
        }
        if !screenRecordingGranted {
            return "Screen capture is on but the Screen Recording permission is missing, so nothing on screen was recorded. Grant it in the Privacy tab."
        }
        if screenshotMode == .storyline && !visionModelReady {
            return "Screen reading is on but no vision model is installed. Install it in Privacy > Local AI."
        }
        if screenshotMode == .thumbnails {
            return "Screen capture is set to Thumbnails, which keeps blurred pictures but writes no detail. Switch it to Storyline in the Privacy tab."
        }
        return "No screen reads for this task yet."
    }

    /// The same reason, short enough to sit under one step of a workflow.
    var noScreenDetailShort: String {
        if !screenCaptureOn { return "(screen capture is off)" }
        if !screenRecordingGranted { return "(Screen Recording permission is missing)" }
        if screenshotMode == .storyline && !visionModelReady { return "(no vision model is installed)" }
        if screenshotMode == .thumbnails { return "(thumbnails mode writes no detail)" }
        return "(no screen detail for this step)"
    }

    // MARK: - Reading the live app

    /// Reads the current state off the engine and macOS.
    static func read(engine: CaptureEngine) -> CoverageStatus {
        CoverageStatus(
            windowTitlesReadable: AXReader.isTrusted,
            telemetryMode: engine.telemetryMode,
            inputMonitoringGranted: Permissions.inputMonitoringGranted,
            screenshotMode: engine.screenshotMode,
            screenRecordingGranted: Permissions.screenRecordingGranted,
            visionModelReady: engine.interpreterReady,
            textModelReady: engine.textModelReady,
            visionModelName: engine.visionModelName,
            textModelName: engine.textModelName)
    }
}

extension CoverageGap.Fix {
    /// Does what the button says, and returns the tab to land on afterwards.
    @MainActor
    func run(_ state: AppState) {
        switch self {
        case .privacy, .localAI:
            break
        case .accessibility:
            AXReader.requestTrust()
            Self.openSettings("com.apple.preference.security?Privacy_Accessibility")
        case .screenRecording:
            _ = Permissions.requestScreenRecording()
            Self.openSettings("com.apple.preference.security?Privacy_ScreenCapture")
        case .inputMonitoring:
            _ = Permissions.requestInputMonitoring()
            Self.openSettings("com.apple.preference.security?Privacy_ListenEvent")
        }
        state.showPrivacy(focusLocalAI: self == .localAI)
    }

    private static func openSettings(_ path: String) {
        if let url = URL(string: "x-apple.systempreferences:\(path)") {
            NSWorkspace.shared.open(url)
        }
    }
}
