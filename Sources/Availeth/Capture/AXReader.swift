import AppKit
import ApplicationServices

/// Thin wrapper over the Accessibility API, used read-only to fetch the
/// focused window's title. The app works without this permission — spans then
/// carry app names only.
enum AXReader {

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt directing the user to System Settings.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Title of the focused window of the given process, or nil when the
    /// permission is missing or the app exposes no title.
    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard isTrusted else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        // AX calls are blocking Mach IPC with a ~6s default timeout; a hung
        // frontmost app must never stall our polling for more than a beat.
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let window = unsafeDowncast(windowRef as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.25)

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success else {
            return nil
        }
        return titleRef as? String
    }

    /// Label and secure-ness of the focused UI element (the field with keyboard
    /// focus). Returns the element's on-screen LABEL — never any value/content it
    /// holds. `isTextInput` is true only for genuine text-entry roles; callers
    /// attribute typing only to those, so non-input elements never get labeled.
    ///
    /// The label is drawn only from label-bearing attributes (a linked title
    /// element, placeholder text, or the accessibility description/title) and is
    /// length-capped, so an element's typed value can't masquerade as its label.
    static func focusedElementLabel(pid: pid_t) -> (label: String, isSecure: Bool, isTextInput: Bool)? {
        guard isTrusted else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        var elementRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &elementRef) == .success,
              let elementRef, CFGetTypeID(elementRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = unsafeDowncast(elementRef as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)

        func string(_ attr: String, of el: AXUIElement) -> String? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
                  let s = ref as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        let role = string(kAXRoleAttribute, of: element) ?? ""
        let subrole = string(kAXSubroleAttribute, of: element) ?? ""
        let isSecure = subrole == (kAXSecureTextFieldSubrole as String)
        let inputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        let isTextInput = isSecure || inputRoles.contains(role) || subrole == (kAXSearchFieldSubrole as String)

        // Label sources, safest first — a linked title element's own title, then
        // placeholder text. The element's own AXTitle/AXDescription are used only
        // as a last resort and only for input roles, length-capped to avoid ever
        // capturing free-form content.
        var label = ""
        var titleUIRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleUIElementAttribute as CFString, &titleUIRef) == .success,
           let titleUIRef, CFGetTypeID(titleUIRef) == AXUIElementGetTypeID() {
            let titleEl = unsafeDowncast(titleUIRef as AnyObject, to: AXUIElement.self)
            label = string(kAXTitleAttribute, of: titleEl) ?? string(kAXValueAttribute, of: titleEl) ?? ""
        }
        if label.isEmpty { label = string(kAXPlaceholderValueAttribute, of: element) ?? "" }
        if label.isEmpty && isTextInput { label = string(kAXTitleAttribute, of: element) ?? string(kAXDescriptionAttribute, of: element) ?? "" }
        if label.count > 60 { label = "" } // too long to be a label — treat as none

        return (label, isSecure, isTextInput)
    }

    /// The URL of the page in the focused browser window, or nil. Read from the
    /// web area's AXURL (WebKit, Chromium and Gecko all expose it), falling back
    /// to the address bar. Bounded: a breadth-first walk of at most `maxNodes`
    /// elements inside a wall-clock budget, each with a short messaging
    /// timeout, so a busy renderer can never stall the caller for long.
    /// Only the host is ever persisted by callers; the URL itself is transient.
    static func focusedPageURL(pid: pid_t, budget: TimeInterval = 1.5, maxNodes: Int = 400) -> URL? {
        guard isTrusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Chromium and Firefox build their web accessibility tree lazily; asking
        // the application for its role is the documented nudge that turns it on.
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &roleRef)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeDowncast(windowRef as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.25)

        // 1. Safari puts the page URL on the window itself.
        if let doc = attribute(kAXDocumentAttribute, of: window) as? String, let url = webURL(doc) { return url }

        // 2. The web area's AXURL, found by a bounded breadth-first walk. Leaf-ish
        //    chrome (toolbars, buttons, tab strips' labels) is not descended into.
        let leafRoles: Set<String> = [
            "AXToolbar", "AXMenuBar", "AXMenu", "AXMenuItem", "AXButton", "AXStaticText", "AXImage",
            "AXPopUpButton", "AXRadioButton", "AXCheckBox", "AXSlider", "AXScrollBar", "AXTextField",
            "AXSafariAddressAndSearchField", "AXProgressIndicator", "AXHeading", "AXLink",
        ]
        let deadline = Date().addingTimeInterval(budget)
        var queue: [AXUIElement] = [window]
        var visited = 0
        var addressBar: URL?
        while !queue.isEmpty, visited < maxNodes, Date() < deadline {
            let el = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(el, 0.15)
            let role = attribute(kAXRoleAttribute, of: el) as? String ?? ""
            if role == "AXWebArea" {
                if let url = urlValue(attribute("AXURL", of: el)), webURL(url.absoluteString) != nil { return url }
                continue
            }
            // The address bar is a fallback only — its value may be mid-edit.
            if addressBar == nil, role == "AXTextField" || role == "AXSafariAddressAndSearchField" {
                let name = (attribute(kAXDescriptionAttribute, of: el) as? String ?? "")
                    + " " + (attribute(kAXTitleAttribute, of: el) as? String ?? "")
                if role == "AXSafariAddressAndSearchField" || name.localizedCaseInsensitiveContains("address") {
                    if let v = attribute(kAXValueAttribute, of: el) as? String { addressBar = webURL(v) }
                }
            }
            if leafRoles.contains(role) { continue }
            if let kids = attribute(kAXChildrenAttribute, of: el) as? [AnyObject] {
                for k in kids where CFGetTypeID(k) == AXUIElementGetTypeID() {
                    queue.append(unsafeDowncast(k, to: AXUIElement.self))
                }
            }
        }
        return addressBar
    }

    private static func attribute(_ attr: String, of el: AXUIElement) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref
    }

    private static func urlValue(_ ref: CFTypeRef?) -> URL? {
        guard let ref else { return nil }
        if let u = ref as? URL { return u }
        if let s = ref as? String { return URL(string: s) }
        return nil
    }

    /// An http(s) URL with a plausible public host — "chrome://", "about:",
    /// "file:", a half-typed "aib" and search text are all rejected.
    static func webURL(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        let candidate = s.range(of: "://") == nil ? "https://" + s : s
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, HostNormalizer.normalise(host) != nil else { return nil }
        return url
    }

    /// File path of the document open in the focused window, or nil.
    /// This is the document's IDENTITY (its path) — never its contents — read
    /// from the standard AX document attribute. No Full Disk Access involved.
    static func focusedDocumentPath(pid: pid_t) -> String? {
        guard isTrusted else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let window = unsafeDowncast(windowRef as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.25)

        var docRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &docRef) == .success,
              let doc = docRef as? String else {
            return nil
        }
        // AX returns a file:// URL string; present the plain filesystem path.
        return URL(string: doc)?.path ?? doc
    }
}
