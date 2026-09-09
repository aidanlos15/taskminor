import Foundation

/// Turns a captured screen frame into a one-line narrative of what the user is
/// doing — the "storyline" layer. Implementations run LOCALLY so the image never
/// leaves the Mac; the image is discarded as soon as the narrative is produced.
protocol SceneInterpreter {
    /// Human-readable name shown in the UI (e.g. "Qwen2.5-VL (local)").
    var displayName: String { get }
    /// Whether the VISION model is reachable/ready right now. Storyline capture
    /// needs this; nothing else does.
    func isAvailable() async -> Bool
    /// Whether the TEXT model is reachable/ready right now. `summarize` sends no
    /// image, so the story layer needs only this, and a text model is a fraction
    /// of the download of a vision one.
    func isTextAvailable() async -> Bool
    /// Produce a short narrative for the frame. `context` carries the app/window
    /// so the model has grounding. Returns nil on failure.
    func narrate(pngData: Data, context: SceneContext) async -> String?
    /// Text-only synthesis (no image) — used to fuse a minute or a task's signals
    /// into a summary. Returns the scrubbed model output, or nil on failure.
    func summarize(prompt: String, maxTokens: Int) async -> String?
    /// As above, with sequences that end generation early (a few-shot prompt
    /// otherwise runs on into a fourth example).
    func summarize(prompt: String, maxTokens: Int, stop: [String]) async -> String?
}

extension SceneInterpreter {
    func summarize(prompt: String, maxTokens: Int, stop: [String]) async -> String? {
        await summarize(prompt: prompt, maxTokens: maxTokens)
    }
}

struct SceneContext {
    var appName: String
    var windowTitle: String
    /// What the user just did that triggered this capture, e.g. "Pasted". "" if
    /// this was a periodic sample rather than an action.
    var action: String = ""
    /// How much detail to report (and whether to scrub content).
    var depth: CaptureDepth = .activity
}

/// Deterministic local scrub of a model-generated narrative. The prompt asks the
/// model not to transcribe specifics, but local models don't always comply — this
/// is the belt-and-braces pass that removes the common PII shapes before storage.
enum NarrativeSanitizer {
    private static let patterns: [(String, String)] = [
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email]"),
        (#"[$£€]\s?\d[\d,]*(?:\.\d+)?"#, "[amount]"),               // $18,672.44
        // Bare decimals BEFORE the id pattern: the id pattern matches the whole
        // part of "18672.44" on its own, which left "[id].44" on screen — the
        // cents still readable and the value mislabelled as an identifier.
        (#"\b\d{3,}[.,]\d+\b"#, "[amount]"),                        // 18672.44
        (#"\b(?:[A-Z]{2,}-)?\d[\d\-]{3,}\d\b"#, "[id]"),           // INV-10247, 4839201
    ]

    static func scrub(_ text: String) -> String {
        var out = text
        for (pattern, replacement) in patterns {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return deidentifySubject(out)
    }

    /// Words that begin a capitalised phrase but are never someone's name, so a
    /// sentence about an app is left alone.
    private static let notAName: Set<String> = [
        "The", "A", "An", "This", "These", "Those", "It", "They", "He", "She", "We", "You", "I",
        "Microsoft", "Google", "Apple", "Adobe", "Safari", "Chrome", "Firefox", "Edge", "Slack",
        "Outlook", "Excel", "Word", "Teams", "Finder", "Preview", "Mail", "Calendar", "Notes",
        "Keynote", "Numbers", "Pages", "Xcode", "Code", "Terminal", "Salesforce", "NetSuite",
        "QuickBooks", "Xero", "Sage", "Jobber", "Zoom", "Dropbox", "Notion", "Figma", "Jira",
        "Purchase", "Vendor", "Invoice", "Invoices", "Deal", "Opportunity", "Inbox", "Search",
        "Data", "Timesheet", "Weekly", "Daily", "Monthly", "Job", "Jobs", "Task", "Tasks",
        "Command", "Admin", "Report", "Reports", "Dashboard", "Settings", "System", "First",
        "During", "After", "Before", "Then", "Next", "Finally", "Throughout", "While", "Using",
    ]

    /// Stops a story being written about a named person.
    ///
    /// Window titles routinely carry the names of customers, colleagues and
    /// records ("Vanessa Baez IP suspicious activity"). A small model handed
    /// those, and told it is describing an employee, picks the nearest name and
    /// writes "Vanessa Baez performs a series of tasks…" — attributing the work
    /// to whoever happened to be on screen. The prompt now forbids it; this is
    /// the deterministic pass for when the model does it anyway.
    ///
    /// It only rewrites a capitalised name used as the SUBJECT of a sentence, so
    /// a customer named inside the work ("updated the Acme Corp record") is
    /// untouched, and app names never match.
    static func deidentifySubject(_ text: String) -> String {
        // TWO or three capitalised words at a sentence start, followed by a
        // lower-case word, optionally possessive ("Vanessa Baez's daily task").
        //
        // Two words is deliberate. A single capitalised word opening a sentence
        // is far more often a verb than a name in this material — "Submitting a
        // vendor bill", "Entering amount", "Searching the spreadsheet" — and an
        // earlier one-word rule rewrote all three as "the user". A first name on
        // its own is left alone rather than risk mangling the account.
        let pattern = #"(^|(?<=[.!?]\s)|(?<=[.!?]\s\s))([A-Z][a-z]{1,20}(?:\s+[A-Z][a-z]{1,20}){1,2})(‘s|'s|’s)?(\s+[a-z])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        var guardCount = 0
        while guardCount < 12 {
            guardCount += 1
            let range = NSRange(out.startIndex..., in: out)
            guard let m = re.firstMatch(in: out, range: range),
                  let nameRange = Range(m.range(at: 2), in: out) else { break }
            let name = String(out[nameRange])
            let first = name.split(separator: " ").first.map(String.init) ?? name
            // Known non-names, and gerunds or past participles, are not people:
            // "Reviewing Purchase Orders", "Updated Vendor Bills".
            let isVerbish = first.hasSuffix("ing") || first.hasSuffix("ed")
            if notAName.contains(first) || isVerbish {
                // Skip past this match so the loop can find a later one.
                guard let after = Range(m.range, in: out) else { break }
                let head = String(out[..<after.upperBound])
                let tail = String(out[after.upperBound...])
                let cleanedTail = deidentifySubject(tail)
                return head + cleanedTail
            }
            let possessive = m.range(at: 3).location != NSNotFound
            let replacement = possessive ? "the user's" : "the user"
            guard let full = Range(m.range(at: 2), in: out) else { break }
            out.replaceSubrange(full, with: replacement)
            if possessive, let posRange = Range(m.range(at: 3), in: out) {
                out.removeSubrange(posRange)
            }
        }
        return out
    }
}

/// A local Ollama vision model. Talks to the Ollama daemon over loopback
/// (127.0.0.1:11434) — the frame is sent to a process on THIS machine only and
/// never touches the internet.
final class OllamaInterpreter: NSObject, SceneInterpreter, URLSessionTaskDelegate {
    /// Reads screen frames. Must be a vision model.
    let visionModel: String
    /// Writes the minute and task stories from signals. `summarize` sends no
    /// image, so this can be a small text-only model (qwen2.5:3b is 1.9 GB
    /// against 6.0 GB for qwen2.5vl:7b).
    let textModel: String
    private let endpoint: URL
    private let host: String
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        config.connectionProxyDictionary = [:] // no proxies
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// `host` defaults to whatever OllamaService resolved: the customer's own
    /// service when they run one, otherwise Availeth's bundled copy.
    init(visionModel: String = "qwen2.5vl:7b", textModel: String = "qwen2.5:3b", host: String = OllamaService.resolvedHost) {
        self.visionModel = visionModel
        self.textModel = textModel
        self.host = host
        self.endpoint = URL(string: "\(host)/api/generate")!
        super.init()
    }

    /// Refuse ALL redirects: the frame must never be re-sent to another host,
    /// even if a process squatting on the loopback port returns a 3xx.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    var displayName: String { "\(visionModel) (local)" }
    var textDisplayName: String { "\(textModel) (local)" }

    func isAvailable() async -> Bool { await isPulled(visionModel) }
    func isTextAvailable() async -> Bool { await isPulled(textModel) }

    /// Names of every model the local daemon has pulled. Empty if it is not running.
    private func pulledModels() async -> [String] {
        guard let url = URL(string: endpoint.absoluteString.replacingOccurrences(of: "/api/generate", with: "/api/tags")) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return []
        }
        return models.compactMap { $0["name"] as? String }
    }

    /// True if the daemon is up and this model (or another tag of its family) is pulled.
    private func isPulled(_ wanted: String) async -> Bool {
        let names = await pulledModels()
        let family = wanted.components(separatedBy: ":").first ?? wanted
        return names.contains { $0 == wanted || $0.hasPrefix(family) }
    }

    /// Privacy-first: one content-free sentence (paired with the PII scrub).
    private static let activityPrompt = """
        In ONE sentence starting with a verb, record what is being done on this screen and in which \
        app and page, for example "Entering a vendor bill in NetSuite" or "Searching a spreadsheet for \
        a purchase order". State only what is visible; do not guess the goal. Do not name or guess who \
        is working: a personal name on screen belongs to a record, a customer or a colleague, never to \
        the person at the keyboard. Do not transcribe personal data, names, numbers, amounts or email \
        addresses.
        """

    /// Detailed: read what's actually on screen so the work can be understood
    /// well enough to judge — and later build — an automation.
    private static let detailedPrompt = """
        Record exactly what is on this screen in three to five sentences, each starting with a verb, \
        so a colleague could follow the step. Cover: the app and the specific page or form (for \
        example "the New Vendor Bill form in NetSuite"); the action under way (for example "typing an \
        invoice number into the Reference field"); the field labels and the values in them, buttons, \
        the subject of an email or document, and the actual question typed if an AI tool is open; and \
        where data is being taken from and put to, when that is visible. Quote short on-screen text. \
        State only what is visible; do not add a purpose or a guess. Do not name or guess who is \
        working: a personal name on screen belongs to a record, a customer or a colleague.
        """

    func narrate(pngData: Data, context: SceneContext) async -> String? {
        let actionHint = context.action.isEmpty ? "" : " The user just: \(context.action)."
        let basePrompt = context.depth == .detailed ? Self.detailedPrompt : Self.activityPrompt
        let maxTokens = context.depth == .detailed ? 320 : 80
        let body: [String: Any] = [
            "model": visionModel,
            "prompt": "\(basePrompt)\n\nApp: \(context.appName). Window: \(context.windowTitle).\(actionHint)",
            "images": [pngData.base64EncodedString()],
            "stream": false,
            "keep_alive": "10m", // keep the model warm between captures
            "options": ["temperature": 0.1, "num_predict": maxTokens],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Detailed mode intentionally keeps on-screen content; activity mode scrubs PII.
        let cleaned = context.depth == .detailed ? trimmed : NarrativeSanitizer.scrub(trimmed)
        return cleaned.isEmpty ? nil : cleaned
    }

    func summarize(prompt: String, maxTokens: Int) async -> String? {
        await summarize(prompt: prompt, maxTokens: maxTokens, stop: [])
    }

    func summarize(prompt: String, maxTokens: Int, stop: [String]) async -> String? {
        // num_ctx is set explicitly: Ollama's default window is 4096 tokens and
        // a prompt that overflows it is cut from the FRONT, which silently
        // drops the rules and examples and keeps only the tail of the record.
        var options: [String: Any] = ["temperature": 0.2, "num_predict": maxTokens, "num_ctx": 8192]
        if !stop.isEmpty { options["stop"] = stop }
        let body: [String: Any] = [
            "model": textModel,
            "prompt": prompt,
            "stream": false,
            "keep_alive": "10m",
            "options": options,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            return nil
        }
        let cleaned = NarrativeSanitizer.scrub(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return cleaned.isEmpty ? nil : cleaned
    }
}
