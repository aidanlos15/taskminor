import Foundation

/// How the Tasks tab decides whether a window title says anything about the
/// work, and how it keys titles so near-identical ones group together. Pure
/// functions, shared by the labeler (which persists labels) and the grouping
/// (which reads them), so they always agree.
enum LabelKey {
    /// " - Google Chrome - Aidan", " — Safari", " | Arc": the browser and, in
    /// Chrome, the profile name after it. normalizeTitle only strips a browser
    /// that ends the title, so the profile tail would otherwise keep a bare
    /// "Claude" tab looking informative.
    private static let browserTail = #/\s[-\u{2014}\u{2013}|]\s(?:Google Chrome|Chromium|Safari|Microsoft Edge|Arc|Firefox|Brave Browser|Brave|Opera|Vivaldi)(?:\s[-\u{2014}\u{2013}]\s[^-\u{2014}\u{2013}]{1,40})?\s*$/#

    /// Titles that name a screen, not a piece of work.
    private static let generic: Set<String> = [
        "new chat", "new conversation", "untitled", "home", "dashboard", "chat",
        "terminal", "zsh", "bash", "finder", "inbox", "new tab", "start page", "loading",
    ]

    /// The title as the row should show it: normalizeTitle, minus a browser +
    /// profile tail, the unsaved-changes bullet, and a trailing count.
    static func cleanTitle(_ raw: String, appName: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if WorkflowUnit.browsers.contains(appName), let m = t.firstMatch(of: browserTail) {
            t = String(t[..<m.range.lowerBound])
        }
        while let first = t.first, "\u{25CF}\u{2022}*".contains(first) {
            t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        t = Analytics.normalizeTitle(t, appName: appName)
        // "Budget.xlsx — Excel" under "Microsoft Excel": the short product name too.
        let short = WorkflowUnit.shortApp(appName)
        if short != appName, !t.hasPrefix("General ") {
            for dash in [" \u{2014} ", " \u{2013} ", " - "] where t.hasSuffix(dash + short) {
                t = String(t.dropLast((dash + short).count)); break
            }
        }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "General \(appName) usage" : t
    }

    /// Lowercased, punctuation stripped, whitespace collapsed — the grouping key.
    static func canonKey(_ s: String) -> String {
        String(s.lowercased().map { ch -> Character in (ch.isLetter || ch.isNumber) ? ch : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Vendor tags a site appends to its own name: "Claude – Anthropic", "ChatGPT | OpenAI".
    private static let vendorTags: Set<String> = [
        "anthropic", "openai", "google", "microsoft", "apple", "meta", "atlassian",
        "salesforce", "official site", "official", "home", "app", "web",
    ]

    /// True when the title says nothing beyond the app/site itself — a bare
    /// "Claude" window, "General X usage", "New chat", "Claude – Anthropic",
    /// "New chat - Claude". "Vendor list - Google Sheets" is informative.
    static func isUninformative(unit: String, cleanTitle: String) -> Bool {
        if cleanTitle.hasPrefix("General ") { return true }
        let key = canonKey(cleanTitle), unitKey = canonKey(unit)
        if key.isEmpty || key == unitKey || generic.contains(key) { return true }
        guard !unitKey.isEmpty else { return false }
        if key.hasPrefix(unitKey + " ") {
            let rest = String(key.dropFirst(unitKey.count + 1))
            return vendorTags.contains(rest) || generic.contains(rest)
        }
        if key.hasSuffix(" " + unitKey) {
            let rest = String(key.dropLast(unitKey.count + 1))
            return generic.contains(rest)
        }
        return false
    }

    // MARK: - Merging near-duplicate titles

    private static let stopwords: Set<String> = [
        "a", "an", "the", "in", "on", "for", "to", "of", "with", "and", "into", "via",
        "from", "at", "by", "up", "about", "using", "my", "our",
    ]

    /// Content words of a title, plural-folded, without stopwords.
    static func words(_ s: String) -> Set<String> {
        Set(canonKey(s).split(separator: " ").map(String.init)
            .filter { !stopwords.contains($0) }
            .map { w in (w.count > 3 && w.hasSuffix("s") && !w.hasSuffix("ss")) ? String(w.dropLast()) : w })
    }

    /// Adopts an existing task title when the new one is plainly the same piece
    /// of work said slightly differently ("Debug the Swift build errors" /
    /// "Debug Swift build error"): word-set Jaccard ≥ 0.75, or one set inside the
    /// other — and never when the words that differ carry a number ("Q3" vs
    /// "Q4"). Deliberately conservative: the model's MATCH line does the real
    /// merging; this only catches paraphrase. Existing titles are never rewritten.
    static func merge(_ title: String, into existing: [String]) -> String {
        let w = words(title)
        guard w.count >= 2 else { return title }
        var best: (title: String, score: Double)?
        for e in existing {
            let ew = words(e)
            guard ew.count >= 2 else { continue }
            if w.symmetricDifference(ew).contains(where: { $0.contains(where: \.isNumber) }) { continue }
            let inter = Double(w.intersection(ew).count)
            let union = Double(w.union(ew).count)
            let jaccard = union > 0 ? inter / union : 0
            let nested = w.isSubset(of: ew) || ew.isSubset(of: w)
            guard jaccard >= 0.75 || nested else { continue }
            if jaccard > (best?.score ?? -1) { best = (e, jaccard) }
        }
        return best?.title ?? title
    }
}
