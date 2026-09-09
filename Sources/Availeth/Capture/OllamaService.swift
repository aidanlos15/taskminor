import Foundation

/// Runs the local model service, so a customer never installs one.
///
/// Availeth ships the Ollama server binary inside its own bundle (MIT licensed,
/// about 31 MB for Apple Silicon) and starts it on a private port as a child
/// process. There is no second app in the Applications folder, no installer, no
/// admin password. The models are still fetched on demand, because 1.9 GB of
/// text model and 6.0 GB of vision model cannot sit in a download that has to be
/// clicked before anyone has seen the product work.
///
/// An Ollama the customer already runs takes precedence: starting a second
/// server against the same model store would download everything twice.
@MainActor
final class OllamaService {
    static let shared = OllamaService()

    /// Where the models live for our own copy: alongside Availeth's data, so
    /// "delete my data" and uninstalling behave predictably.
    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Availeth/models", isDirectory: true)
    }

    /// The default port; ours avoids it so the two never collide.
    static let sharedPort = 11434
    static let privatePort = 11477

    private(set) var host = "http://127.0.0.1:\(sharedPort)"

    /// The host as last resolved, readable from any thread for defaults.
    nonisolated(unsafe) static var resolvedHost = "http://127.0.0.1:\(OllamaService.sharedPort)"
    private var process: Process?

    /// The bundled server, if this build shipped one.
    static var bundledBinary: URL? {
        guard let url = Bundle.main.url(forResource: "ollama", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    private static func reachable(_ host: String) async -> Bool {
        guard let url = URL(string: "\(host)/api/tags") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Resolves a working host: the customer's own service if it is up, else our
    /// bundled one, started now. Returns nil when neither is available, which is
    /// what the Privacy tab reports and offers a download for.
    @discardableResult
    func ensureRunning() async -> String? {
        let theirs = "http://127.0.0.1:\(Self.sharedPort)"
        if await Self.reachable(theirs) { host = theirs; Self.resolvedHost = theirs; return theirs }

        let ours = "http://127.0.0.1:\(Self.privatePort)"
        if await Self.reachable(ours) { host = ours; Self.resolvedHost = ours; return ours }

        guard let binary = Self.bundledBinary else { return nil }
        defer { Self.resolvedHost = host }
        try? FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = binary
        p.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_HOST"] = "127.0.0.1:\(Self.privatePort)"
        env["OLLAMA_MODELS"] = Self.modelsDirectory.path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        process = p

        // The server needs a moment to bind before it answers.
        for _ in 0..<20 {
            if await Self.reachable(ours) { host = ours; Self.resolvedHost = ours; return ours }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    /// Stops our own copy. A service the customer runs is left alone.
    func shutdown() {
        process?.terminate()
        process = nil
    }
}
