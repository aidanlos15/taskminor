import Foundation

/// Turns a captured screen frame into a one-line narrative of what the user is
/// doing — the "storyline" layer. Implementations run LOCALLY so the image never
/// leaves the Mac; the image is discarded as soon as the narrative is produced.
protocol SceneInterpreter {
    /// Human-readable name shown in the UI (e.g. "Qwen2.5-VL (local)").
    var displayName: String { get }
    /// Whether the interpreter is reachable/ready right now.
    func isAvailable() async -> Bool
    /// Produce a short narrative for the frame. `context` carries the app/window
    /// so the model has grounding. Returns nil on failure.
    func narrate(pngData: Data, context: SceneContext) async -> String?
    /// Text-only synthesis (no image) — used to fuse a minute or a task's signals
    /// into a summary. Returns the scrubbed model output, or nil on failure.
    func summarize(prompt: String, maxTokens: Int) async -> String?
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
        (#"\b(?:[A-Z]{2,}-)?\d[\d\-]{3,}\d\b"#, "[id]"),           // INV-10247, 4839201
        (#"\b\d{3,}[.,]\d+\b"#, "[amount]"),                        // 18672.44
    ]

    static func scrub(_ text: String) -> String {
        var out = text
        for (pattern, replacement) in patterns {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return out
    }
}

/// A local Ollama vision model. Talks to the Ollama daemon over loopback
/// (127.0.0.1:11434) — the frame is sent to a process on THIS machine only and
/// never touches the internet.
final class OllamaInterpreter: NSObject, SceneInterpreter, URLSessionTaskDelegate {
    let model: String
    private let endpoint: URL
    private let host: String
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        config.connectionProxyDictionary = [:] // no proxies
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(model: String = "qwen2.5vl:7b", host: String = "http://127.0.0.1:11434") {
        self.model = model
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

    var displayName: String { "\(model) (local)" }

    func isAvailable() async -> Bool {
        guard let url = URL(string: endpoint.absoluteString.replacingOccurrences(of: "/api/generate", with: "/api/tags")) else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return false
        }
        // Available if the daemon is up and our model (or any qwen vl) is pulled.
        let names = models.compactMap { $0["name"] as? String }
        return names.contains { $0 == model || $0.hasPrefix(model.components(separatedBy: ":").first ?? model) }
    }

    /// Privacy-first: one content-free sentence (paired with the PII scrub).
    private static let activityPrompt = """
        You are observing an employee's screen to map their work process. In ONE concise sentence, \
        describe the task the person appears to be doing and the app/screen they are in. \
        Focus on the ACTION and WORKFLOW STEP (e.g. "Entering a vendor bill in an accounting system", \
        "Searching a spreadsheet for a purchase order"). \
        Do NOT transcribe or repeat any specific personal data, names, numbers, amounts, or email \
        addresses you see. Describe the activity, not the contents.
        """

    /// Detailed: read what's actually on screen so the work can be understood
    /// well enough to judge — and later build — an automation.
    private static let detailedPrompt = """
        You are documenting exactly what is happening on this screen so a colleague could understand \
        the work and decide whether it can be automated. Be specific and concrete — describe what is \
        actually visible, do not generalise. Cover, in a short paragraph:
        • The exact app and the specific screen/page (e.g. "the New Vendor Bill form in NetSuite", "a Calendly booking page for a 30-min meeting").
        • The specific action being taken right now (e.g. "typing an invoice number into the Reference field", "selecting a time slot").
        • The concrete on-screen content that matters to the task: form field labels AND the values in them, buttons, the subject of an email or document, and — if an AI tool (ChatGPT/Claude) is open — the actual question or prompt being asked.
        • Where data appears to be coming from and going to (e.g. "copying the total from the PDF to paste into the ERP").
        • The apparent goal of this step.
        Write 3–5 sentences of concrete detail. It is fine to quote short on-screen text.
        """

    func narrate(pngData: Data, context: SceneContext) async -> String? {
        let actionHint = context.action.isEmpty ? "" : " The user just: \(context.action)."
        let basePrompt = context.depth == .detailed ? Self.detailedPrompt : Self.activityPrompt
        let maxTokens = context.depth == .detailed ? 320 : 80
        let body: [String: Any] = [
            "model": model,
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
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "keep_alive": "10m",
            "options": ["temperature": 0.2, "num_predict": maxTokens],
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
