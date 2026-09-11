import Foundation

/// Turns a page URL read from a browser tab into the two keys the site-icon
/// pipeline uses: the host (kept on the span) and the registrable domain (the
/// icon key, so every AIB host shares one mark). The full URL is never stored.
enum HostNormalizer {
    /// Public second-level suffixes under which the registrable domain is three
    /// labels (foo.co.uk, not co.uk). A short list, not the Public Suffix List;
    /// a miss just keys an icon per host instead of per brand.
    private static let secondLevel: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk", "ltd.uk", "plc.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "co.nz", "org.nz", "net.nz",
        "co.za", "co.jp", "ne.jp", "or.jp", "ac.jp", "com.br", "com.mx", "com.ar",
        "com.sg", "com.hk", "com.tw", "co.in", "co.kr", "com.cn", "com.tr", "co.il",
        "com.my", "co.th", "com.ph", "com.vn", "com.pk", "com.ng", "co.ke", "com.co",
    ]

    /// The host of an http(s) URL, lowercased, without a trailing dot or a
    /// leading "www."; nil for other schemes, IP literals, local names and
    /// single-label hosts (nothing to look an icon up for).
    static func host(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let h = url.host else { return nil }
        return normalise(h)
    }

    /// Same cleaning for a bare host string (an address-bar value, say).
    static func normalise(_ raw: String) -> String? {
        var h = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
        if let colon = h.firstIndex(of: ":") { h = String(h[..<colon]) }
        while h.hasSuffix(".") { h.removeLast() }
        for p in ["www.", "www2.", "m."] where h.hasPrefix(p) && h.count > p.count + 3 {
            h = String(h.dropFirst(p.count)); break
        }
        return isValid(h) ? h : nil
    }

    /// A plausible public hostname: hostname characters only, at least two
    /// labels, an alphabetic TLD, not an IP literal, not .local/localhost.
    static func isValid(_ h: String) -> Bool {
        guard h.count <= 253, h.contains("."),
              h.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
              h != "localhost", !h.hasSuffix(".local"), !h.hasSuffix(".localhost") else { return false }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return true
    }

    /// onlinebanking.aib.ie → aib.ie; docs.google.com → google.com; a.foo.co.uk → foo.co.uk.
    static func registrableDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host.lowercased() }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        return secondLevel.contains(lastTwo) ? labels.suffix(3).joined(separator: ".") : lastTwo
    }

    /// Domains shared by unrelated services or tenants: their icons are keyed
    /// per host, so docs.google.com and mail.google.com never trade marks.
    private static let sharedDomains: Set<String> = [
        "google.com", "microsoft.com", "live.com", "office.com", "sharepoint.com", "azurewebsites.net",
        "github.io", "gitlab.io", "herokuapp.com", "netlify.app", "vercel.app", "pages.dev", "web.app",
        "myshopify.com", "substack.com", "wordpress.com", "blogspot.com", "notion.site",
        "amazonaws.com", "cloudfront.net",
    ]

    /// The key an icon is stored under: the brand's registrable domain (every
    /// AIB host shares aib.ie), or the full host on a shared domain.
    static func iconKey(host: String) -> String {
        let h = host.lowercased()
        let d = registrableDomain(h)
        return sharedDomains.contains(d) ? h : d
    }

    // MARK: - Sites that already have a bundled mark

    /// Full host → Resources/Logos key, for services that share a domain.
    private static let hostMarks: [String: String] = [
        "docs.google.com": "googledocs", "sheets.google.com": "googlesheets",
        "drive.google.com": "googledrive", "calendar.google.com": "googlecalendar",
        "mail.google.com": "gmail",
        "outlook.live.com": "outlook", "outlook.office.com": "outlook", "outlook.office365.com": "outlook",
        "teams.microsoft.com": "teams", "teams.live.com": "teams",
        "app.slack.com": "slack", "qbo.intuit.com": "quickbooks", "app.qbo.intuit.com": "quickbooks",
        "docs.anthropic.com": "claude", "console.anthropic.com": "claude",
        "chat.openai.com": "chatgpt", "platform.openai.com": "chatgpt",
    ]

    /// Registrable domain → Resources/Logos key.
    private static let domainMarks: [String: String] = [
        "claude.ai": "claude", "anthropic.com": "claude", "chatgpt.com": "chatgpt", "openai.com": "chatgpt",
        "github.com": "github", "notion.so": "notion", "notion.site": "notion",
        "atlassian.net": "jira", "linkedin.com": "linkedin", "figma.com": "figma",
        "hubspot.com": "hubspot", "xero.com": "xero", "salesforce.com": "salesforce", "force.com": "salesforce",
        "netsuite.com": "netsuite", "asana.com": "asana", "trello.com": "trello", "dropbox.com": "dropbox",
        "zoom.us": "zoom", "upwork.com": "upwork", "slack.com": "slack", "gmail.com": "gmail",
        "stripe.com": "stripe", "zendesk.com": "zendesk", "airtable.com": "airtable",
        "calendly.com": "calendly", "youtube.com": "youtube", "amazon.com": "amazon", "amazon.co.uk": "amazon",
    ]

    /// The bundled brand mark for a host, when there is one — crisper than any
    /// favicon, so it wins over the browser cache.
    static func bundledMark(host: String) -> String? {
        let h = host.lowercased()
        if let k = hostMarks[h] { return k }
        return domainMarks[registrableDomain(h)]
    }

    /// Every Logos key the maps can produce (for the asset test).
    static var bundledMarkKeys: Set<String> { Set(hostMarks.values).union(domainMarks.values) }
}
