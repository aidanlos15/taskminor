import Foundation

/// The unit a workflow step is really about. For a browser, that's the
/// site/service in the tab (NetSuite, Gmail, Temu…) — NOT "Chrome" — so distinct
/// tabs are never lumped together. For any other app it's the app itself.
///
/// Shared by the miner (which sequences on this) and the insight builder (which
/// matches captured data to steps by this), so they always agree.
enum WorkflowUnit {
    static let browsers: Set<String> = [
        "Google Chrome", "Chromium", "Safari", "Microsoft Edge", "Arc",
        "Firefox", "Brave Browser", "Opera", "Vivaldi",
    ]

    /// The unit label for a span.
    static func label(app: String, title: String) -> String {
        if browsers.contains(app) {
            return service(fromBrowserTitle: title) ?? shortApp(app)
        }
        return shortApp(app)
    }

    static func shortApp(_ name: String) -> String {
        name.replacingOccurrences(of: "Microsoft ", with: "")
            .replacingOccurrences(of: "Google ", with: "")
            .replacingOccurrences(of: " Browser", with: "")
    }

    /// Extracts the site/service from a browser window title.
    static func service(fromBrowserTitle raw: String) -> String? {
        // 1. Strip the "… - Google Chrome - Profile" tail: keep text before the browser name.
        var t = raw
        for browser in browsers {
            for sep in [" - ", " — ", " – ", " | "] {
                if let r = t.range(of: sep + browser) { t = String(t[..<r.lowerBound]); break }
            }
        }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let lower = t.lowercased()

        // 2. Known-service keyword match — the most reliable signal.
        for (name, keys) in knownServices where keys.contains(where: { lower.contains($0) }) {
            return name
        }
        // 3. "Page — Site" / "Page | Site" convention: the site is usually last.
        for sep in [" — ", " – ", " | ", " · ", " - "] {
            if let r = t.range(of: sep, options: .backwards) {
                let last = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !last.isEmpty, last.count <= 24, last.split(separator: " ").count <= 3 {
                    return last
                }
            }
        }
        // 4. Fallback: the first few words of the page title (its own identity).
        let words = t.split(separator: " ").prefix(3).joined(separator: " ")
        return words.isEmpty ? nil : String(words)
    }

    private static let knownServices: [(String, [String])] = [
        ("NetSuite", ["netsuite"]), ("Salesforce", ["salesforce", "lightning.force"]),
        ("Gmail", ["gmail"]), ("Google Docs", ["google docs"]), ("Google Sheets", ["google sheets"]),
        ("Google Drive", ["google drive"]), ("Google Calendar", ["google calendar"]),
        ("Outlook", ["outlook"]), ("LinkedIn", ["linkedin"]), ("GitHub", ["github"]),
        ("Notion", ["notion"]), ("Jira", ["jira"]), ("Confluence", ["confluence"]),
        ("ChatGPT", ["chatgpt", "chat.openai"]), ("Claude", ["claude.ai", "claude"]),
        ("Figma", ["figma"]), ("YouTube", ["youtube"]), ("Amazon", ["amazon"]),
        ("Temu", ["temu"]), ("Upwork", ["upwork"]), ("QuickBooks", ["quickbooks"]),
        ("Stripe", ["stripe"]), ("Zoom", ["zoom.us", "zoom meeting"]), ("HubSpot", ["hubspot"]),
        ("Xero", ["xero"]), ("Zendesk", ["zendesk"]), ("Base44", ["base44"]),
        ("Calendly", ["calendly"]), ("Airtable", ["airtable"]), ("Asana", ["asana"]),
    ]
}
