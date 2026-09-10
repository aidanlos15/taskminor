import Foundation

/// The one place that writes and reads the stored window list on a minute or a
/// task row.
///
/// A minute row holds one entry per window, each "App — Title". Those entries
/// used to be joined with a comma, so any title with a comma in it broke into
/// pieces and the pieces were read back as separate apps. Real rows from the
/// store: "Safari — The New York Times - Breaking News, US News, World News and
/// Videos" came back as three apps, two of them nonsense.
///
/// New rows are joined with the ASCII unit separator, which cannot appear in a
/// window title. Old rows are still read, with the comma rule below: a piece
/// only starts a new entry if it carries an "App — " prefix or is the name of
/// an app we know. Anything else is a fragment of the title before it and is
/// glued back on.
enum AppList {

    /// ASCII unit separator (U+001F). Never present in a window title.
    static let separator = "\u{1F}"

    /// Apps seen often enough that a bare name is an app, not a title fragment.
    static let knownApps: Set<String> = [
        "activity monitor", "arc", "availeth", "brave browser", "calendar", "chatgpt", "claude",
        "code", "console", "cursor", "discord", "dock", "docker", "figma", "finder", "firefox",
        "google chrome", "iterm2", "jira", "keynote", "linear", "loginwindow", "loom", "mail",
        "messages", "microsoft edge", "microsoft excel", "microsoft outlook", "microsoft powerpoint",
        "microsoft teams", "microsoft word", "music", "nordvpn", "notes", "notion", "numbers",
        "obsidian", "ollama", "pages", "photo booth", "photos", "postman", "preview",
        "quicktime player", "reminders", "safari", "screenshot", "securityagent", "simulator",
        "slack", "sourcetree", "spotify", "system settings", "terminal", "textedit",
        "usernotificationcenter", "xcode", "zoom",
    ]

    /// Stores a list of window labels. Use this for every write.
    static func join(_ items: [String]) -> String {
        items.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    /// Window labels from a stored list, in order. Reads both the new format
    /// and the old comma one. Use this for every read.
    static func parse(_ stored: String) -> [String] {
        if stored.contains(separator) {
            return stored.components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return parseLegacy(stored)
    }

    /// Distinct app names from a stored list, in order, with titles dropped.
    static func appNames(_ stored: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for label in parse(stored) {
            var app = (label.components(separatedBy: " — ").first ?? "")
                .trimmingCharacters(in: .whitespaces)
            // An old row that lost its dash still starts with the app name, so
            // "Safari, US News, World News and Videos" is Safari.
            if let head = app.components(separatedBy: ", ").first,
               head != app, knownApps.contains(head.lowercased()) {
                app = head
            }
            guard !app.isEmpty, seen.insert(app).inserted else { continue }
            out.append(app)
        }
        return out
    }

    // MARK: - Old rows

    private static func parseLegacy(_ stored: String) -> [String] {
        let tokens = stored.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // App names that this same row spells out in full, so a bare repeat of
        // one later in the row is recognised even if we have never seen it.
        var namesHere = Set<String>()
        for t in tokens where t.contains(" — ") {
            if let app = t.components(separatedBy: " — ").first {
                namesHere.insert(app.trimmingCharacters(in: .whitespaces).lowercased())
            }
        }

        var out: [String] = []
        for token in tokens {
            if out.isEmpty || startsNewEntry(token, alsoKnown: namesHere) {
                out.append(token)
            } else {
                // A fragment of the title before it - put it back where it came
                // from rather than letting it pose as an app.
                out[out.count - 1] += ", " + token
            }
        }
        return out
    }

    static func startsNewEntry(_ token: String, alsoKnown: Set<String> = []) -> Bool {
        if token.contains(" — ") { return true }
        let name = token.lowercased()
        return knownApps.contains(name) || alsoKnown.contains(name)
    }
}
