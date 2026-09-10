import AppKit
import Carbon.HIToolbox

/// Reconstructs the STRUCTURE of keyboard/pointer interaction without ever
/// reading typed content.
///
/// Context-gated by design: the monitor only counts or attributes anything when
/// the CaptureEngine has marked the current context capturable (`counting`) and
/// non-secure (`secure == false`). The engine sets that context from the tick
/// loop and via off-main Accessibility reads — the event callback itself never
/// calls Accessibility and never blocks.
///
/// What it records: shortcut chords (⌘C, ⌘V, ⌘F…), navigation/control keys,
/// counts of content keystrokes and clicks, and which on-screen field was typed
/// into. What it never does: read `event.characters` for a content key. The only
/// character read anywhere is `charactersIgnoringModifiers` while ⌘/⌃ is held,
/// solely to name a shortcut.
final class InputMonitor {

    var mode: InputTelemetryMode = .off

    /// Context pushed by the engine (main-thread only). When `counting` is false
    /// or `secure` is true, every event is dropped.
    private(set) var counting = false
    private(set) var secure = false
    private var fieldLabel = ""
    private var fieldClass: String?

    /// Called (throttled) on the first content key after focus may have moved,
    /// so the engine can refresh the field context off the main thread.
    var onNeedFieldRefresh: (() -> Void)?

    /// Fired when a meaningful action happens (copy, paste, cut, save, or filling
    /// a field), so the engine can capture a screenshot at that moment. Carries a
    /// generic, content-free description of the action.
    var onAction: ((String) -> Void)?

    /// Content keys typed since the last field commit — lets us tell a
    /// value-committing Tab/Enter from bare navigation.
    private var contentSinceCommit = 0

    private(set) var keystrokes = 0
    private(set) var clicks = 0
    private var shortcutCounts: [String: Int] = [:]
    private var navCounts: [String: Int] = [:]
    private var fieldOrder: [String] = []
    private var fieldSeen: Set<String> = []

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var lastRefreshRequest = Date.distantPast

    var isRunning: Bool { keyMonitor != nil || mouseMonitor != nil }

    // MARK: - Context (main-thread only)

    func setCounting(_ on: Bool) {
        counting = on
        if !on { secure = false }
    }

    func setField(label: String, secure: Bool, className: String?) {
        // Focus moved to a different field: content typed into the previous field
        // must not count toward committing this one (avoids a false "Filled a
        // field" when the user clicks into an empty field and presses Tab).
        if label != fieldLabel { contentSinceCommit = 0 }
        self.secure = secure
        self.fieldLabel = label
        self.fieldClass = className
    }

    // MARK: - Lifecycle

    func start() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKey(event)
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, self.counting, !self.secure, !IsSecureEventInputEnabled() else { return }
            self.clicks += 1
        }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
        reset()
    }

    // MARK: - Key handling (main thread; never calls Accessibility)

    private func handleKey(_ event: NSEvent) {
        // Gate 1: engine says this context isn't capturable (paused, suspended,
        // excluded/self app, idle, telemetry off).
        guard counting else { return }
        // Gate 2: secure field — via the engine's per-field AX check OR the OS's
        // own process-global secure-input flag. Either one drops the event, so
        // password fields produce nothing, not even a count.
        if secure || IsSecureEventInputEnabled() { return }

        let flags = event.modifierFlags
        let hasCommandOrControl = flags.contains(.command) || flags.contains(.control)

        // Shortcut chords first, so ⌘← is a shortcut, not a bare nav key.
        if hasCommandOrControl {
            let name = shortcutName(event)
            shortcutCounts[name, default: 0] += 1
            // Meaningful data-movement / save actions are capture triggers.
            if let action = Self.actionForShortcut(name) { onAction?(action) }
            return
        }
        // Navigation / control keys — identified by keyCode, no character read.
        if let navName = Self.navKeyName(event.keyCode) {
            navCounts[navName, default: 0] += 1
            // Tab/Enter after typing = committing a value into a field.
            if (navName == "Tab" || navName == "↵"), contentSinceCommit > 0 {
                contentSinceCommit = 0
                onAction?("Filled a field")
            }
            return
        }
        // Content key: COUNT only. The character is never read.
        keystrokes += 1
        contentSinceCommit += 1
        attributeField()
    }

    /// Maps a shortcut name to a generic action label worth capturing, or nil.
    private static func actionForShortcut(_ name: String) -> String? {
        switch name {
        case "⌘C": return "Copied"
        case "⌘X": return "Cut"
        case "⌘V": return "Pasted"
        case "⌘S": return "Saved"
        default: return nil
        }
    }

    private func attributeField() {
        guard mode != .off else { return }
        // Ask the engine to refresh the field context off-main, throttled.
        let now = Date()
        if now.timeIntervalSince(lastRefreshRequest) > 0.8 {
            lastRefreshRequest = now
            onNeedFieldRefresh?()
        }
        guard !fieldLabel.isEmpty else { return }
        let label = (mode == .deep && fieldClass != nil) ? "\(fieldLabel) [\(fieldClass!)]" : fieldLabel
        if !fieldSeen.contains(label) {
            fieldSeen.insert(label)
            fieldOrder.append(label)
        }
    }

    // MARK: - Naming

    private func shortcutName(_ event: NSEvent) -> String {
        var name = ""
        let f = event.modifierFlags
        if f.contains(.control) { name += "⌃" }
        if f.contains(.option) { name += "⌥" }
        if f.contains(.shift) { name += "⇧" }
        if f.contains(.command) { name += "⌘" }
        if let nav = Self.navKeyName(event.keyCode) {
            name += nav
        } else if let key = event.charactersIgnoringModifiers, !key.isEmpty {
            name += key.uppercased()
        } else {
            name += "?"
        }
        return name
    }

    private static func navKeyName(_ code: UInt16) -> String? {
        switch Int(code) {
        case kVK_Tab: return "Tab"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↵"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "PgUp"
        case kVK_PageDown: return "PgDn"
        default: return nil
        }
    }

    // MARK: - Drain / reset

    /// Reads and clears everything accumulated for the closing span.
    func drain() -> (keystrokes: Int, clicks: Int, shortcuts: String, fields: String) {
        let summary = (keystrokes, clicks, shortcutSummary(), fieldOrder.prefix(8).joined(separator: ", "))
        reset()
        return summary
    }

    func reset() {
        keystrokes = 0
        clicks = 0
        shortcutCounts = [:]
        navCounts = [:]
        fieldOrder = []
        fieldSeen = []
        fieldLabel = ""
        fieldClass = nil
        contentSinceCommit = 0
        lastRefreshRequest = .distantPast
    }

    /// "⌘C×12, ⌘V×12, Tab×40, ↵×6" — top chords and nav keys by frequency.
    private func shortcutSummary() -> String {
        let merged = shortcutCounts.merging(navCounts) { a, b in a + b }
        return merged
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(8)
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: ", ")
    }
}

/// Derives a semantic class from a field's on-screen LABEL (never its contents).
/// Matches whole words (or explicit multi-word phrases) so short tokens like
/// "id"/"no" don't fire on "Hidden"/"Notes".
enum FieldClassifier {

    /// True when a captured label reads like a real field label.
    ///
    /// The accessibility API hands back whatever the app puts on the element,
    /// and plenty of it is not a label at all. Real junk that used to be stored
    /// as fields: "5", "2", "example.com", "https://commandcentre.availeth.io/"
    /// and "Twitter...". A label must have at least two letters, must not be a
    /// web address, and must not be cut-off screen text.
    static func isUsableLabel(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 60 else { return false }
        // Cut-off text from the screen, not a label.
        if t.hasSuffix("…") || t.hasSuffix("...") { return false }
        if looksLikeWebAddress(t) { return false }
        // Two letters at least, so numbers and single letters are out.
        return t.filter(\.isLetter).count >= 2
    }

    /// A URL or a bare domain such as "example.com".
    static func looksLikeWebAddress(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") { return true }
        guard !lower.contains(" "), lower.contains(".") else { return false }
        let host = lower.split(separator: "/").first.map(String.init) ?? lower
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let tld = parts.last else { return false }
        return tld.count >= 2 && tld.count <= 24 && tld.allSatisfy(\.isLetter)
            && parts.dropLast().allSatisfy { !$0.isEmpty }
    }

    static func classify(_ label: String) -> String? {
        let lower = label.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        func word(_ ws: String...) -> Bool { ws.contains { words.contains($0) } }
        func phrase(_ ps: String...) -> Bool { ps.contains { lower.contains($0) } }

        if word("amount", "total", "price", "cost", "balance", "subtotal") || phrase("$") { return "currency" }
        if word("email") || phrase("e-mail") { return "email" }
        if word("phone", "mobile", "tel", "telephone") { return "phone" }
        if word("date", "due", "expiry", "expiration") { return "date" }
        if word("invoice", "reference", "ref", "number", "id", "po", "sku") || phrase("po#", "po number", "order no", "order #") { return "identifier" }
        if word("name", "customer", "vendor", "supplier", "contact", "company") { return "name" }
        if word("address", "street", "city", "zip", "postcode", "state", "country") { return "address" }
        if word("search", "find", "query", "filter") { return "search" }
        return nil
    }
}
