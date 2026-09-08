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

    /// File path of the document open in the focused window, or nil.
    /// This is the document's IDENTITY (its path) — never its contents — read
    /// from the standard AX document attribute. No Full Disk Access involved.
    /// The URL of the page in the focused browser window, from the web area's
    /// AXURL attribute. Bounded breadth-first search with the same short
    /// messaging timeout as the title read, so a hung browser never stalls a tick.
    static func focusedBrowserURL(pid: pid_t) -> URL? {
        guard isTrusted else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeDowncast(windowRef as AnyObject, to: AXUIElement.self)

        var queue: [AXUIElement] = [window]
        var visited = 0
        while !queue.isEmpty && visited < 250 {
            let el = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(el, 0.25)
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, role == "AXWebArea" {
                var urlRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXURLAttribute as CFString, &urlRef) == .success,
                   let urlRef, CFGetTypeID(urlRef) == CFURLGetTypeID() {
                    return (urlRef as! CFURL) as URL
                }
                if let str = urlRef as? String, let url = URL(string: str) { return url }
            }
            var kidsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
               let kids = kidsRef as? [AXUIElement] {
                queue.append(contentsOf: kids.prefix(40))
            }
        }
        return nil
    }

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
