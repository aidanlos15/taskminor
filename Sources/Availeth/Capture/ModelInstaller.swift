import Foundation

/// Pulls a local model through the Ollama daemon, with progress, so a customer
/// never opens a terminal.
///
/// Why the models are not in the download: Ollama itself is 196 MB and MIT
/// licensed, but the models are 1.9 GB (text) and 6.0 GB (vision). An app that
/// costs six gigabytes before it shows anything does not get installed. So the
/// app ships small, and fetches only the model the customer actually turns on,
/// here, with a progress bar.
@MainActor
final class ModelInstaller: ObservableObject {
    enum State: Equatable {
        case idle
        case pulling(percent: Double, detail: String)
        case done
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Which model this installer is currently working on.
    @Published private(set) var model: String = ""

    private let host: String
    private var task: Task<Void, Never>?

    init(host: String = OllamaService.resolvedHost) { self.host = host }

    var isBusy: Bool { if case .pulling = state { return true }; return false }

    /// Whether the Ollama daemon is answering at all.
    static func daemonRunning(host: String = OllamaService.resolvedHost) async -> Bool {
        guard let url = URL(string: "\(host)/api/tags") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 3
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    func cancel() {
        task?.cancel(); task = nil
        if isBusy { state = .idle }
    }

    /// Streams `POST /api/pull`. Ollama reports total and completed bytes per
    /// line of newline-delimited JSON.
    func pull(_ name: String) {
        guard !isBusy else { return }
        model = name
        state = .pulling(percent: 0, detail: "Starting…")
        task = Task { [host] in
            guard let url = URL(string: "\(host)/api/pull") else {
                self.state = .failed("Could not reach the local model service."); return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
            req.timeoutInterval = 60

            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    self.state = .failed("The local model service refused the download."); return
                }
                for try await line in bytes.lines {
                    if Task.isCancelled { self.state = .idle; return }
                    guard let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if let err = obj["error"] as? String { self.state = .failed(err); return }
                    let status = (obj["status"] as? String) ?? ""
                    if let total = obj["total"] as? Double, let done = obj["completed"] as? Double, total > 0 {
                        self.state = .pulling(percent: min(1, done / total),
                                              detail: "\(Self.gb(done)) of \(Self.gb(total))")
                    } else {
                        self.state = .pulling(percent: 0, detail: status.isEmpty ? "Working…" : status)
                    }
                    if status == "success" { self.state = .done; return }
                }
                self.state = .done
            } catch {
                self.state = .failed(Self.daemonHint(error))
            }
        }
    }

    private static func gb(_ bytes: Double) -> String {
        bytes >= 1e9 ? String(format: "%.1f GB", bytes / 1e9) : String(format: "%.0f MB", bytes / 1e6)
    }

    private static func daemonHint(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && (ns.code == NSURLErrorCannotConnectToHost || ns.code == NSURLErrorNetworkConnectionLost) {
            return "Ollama is not running on this Mac. Install it, then try again."
        }
        return "The download stopped: \(ns.localizedDescription)"
    }
}
