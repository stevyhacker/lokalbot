import Foundation
import Darwin

/// Built-in LLM backend, part 3 of 3: the bundled llama-server subprocess
/// lifecycle. One model loaded at a time; switching models restarts the server.
/// Stopped when the app quits.
actor LlamaServer {

    /// Chat/completions instance (summaries, digests, Q&A).
    static let shared = LlamaServer(port: 17872, extraArgs: [])
    /// Embeddings instance (semantic search) — small model, second port.
    static let embedder = LlamaServer(port: 17873,
                                      extraArgs: ["--embeddings", "--pooling", "mean"])
    /// Cotyping instance — an optional separate (typically smaller/faster)
    /// model on a third port, so inline suggestions never contend with the
    /// summarizer for the shared server (no model-reload thrash).
    static let cotyping = LlamaServer(port: 17874, extraArgs: [])

    nonisolated let port: Int
    private let extraArgs: [String]
    nonisolated var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    init(port: Int, extraArgs: [String]) {
        self.port = port
        self.extraArgs = extraArgs
    }

    private var process: Process?
    private var loadedModelPath: String?

    enum ServerError: LocalizedError {
        case binaryMissing
        case modelMissing(String)
        case failedToStart(String)
        var errorDescription: String? {
            switch self {
            case .binaryMissing: "Bundled llama-server is missing from the app."
            case .modelMissing(let name): "Model \(name) is not downloaded yet (Settings → Models)."
            case .failedToStart(let detail): "Local LLM server failed to start: \(detail)"
            }
        }
    }

    func ensureRunning(modelAt url: URL) async throws {
        if let process, process.isRunning, loadedModelPath == url.path,
           await healthy() { return }
        try await start(modelAt: url)
    }

    private func start(modelAt url: URL) async throws {
        await stop()
        let binary = try installedBinary()
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "-m", url.path,
            "--host", "127.0.0.1", "--port", String(port),
            "-c", extraArgs.contains("--embeddings") ? "2048" : "16384",
            "-ngl", "99",           // full Metal offload
            "--jinja",              // correct chat templates (qwen3, gpt-oss)
            "--no-webui",
        ] + extraArgs
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        loadedModelPath = url.path

        // Model load can take a while for the big ones; poll /health.
        for _ in 0..<240 {
            try await Task.sleep(for: .milliseconds(500))
            if await healthy() { return }
            if !process.isRunning {
                throw ServerError.failedToStart("llama-server exited during startup")
            }
        }
        await stop()
        throw ServerError.failedToStart("server did not become healthy in time")
    }

    func stop() async {
        let old = process
        process = nil
        loadedModelPath = nil
        guard let old, old.isRunning else { return }
        old.terminate()
        for _ in 0..<40 {
            if !old.isRunning { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if old.isRunning {
            kill(old.processIdentifier, SIGKILL)
        }
    }

    private func healthy() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// llama-server + dylibs are copied out of the bundle into Application
    /// Support on first run (never execute from inside Resources), then
    /// reused. Re-copied if the bundled version changes.
    private func installedBinary() throws -> URL {
        guard let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("llama-cpp", isDirectory: true),
              FileManager.default.fileExists(atPath: bundled.appendingPathComponent("llama-server").path)
        else { throw ServerError.binaryMissing }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
            .appendingPathComponent(AppIdentifiers.bundleID)
        let installed = appSupport.appendingPathComponent("llama-cpp", isDirectory: true)
        let binary = installed.appendingPathComponent("llama-server")

        let bundledSize = (try? FileManager.default.attributesOfItem(
            atPath: bundled.appendingPathComponent("llama-server").path)[.size] as? Int) ?? 0
        let installedSize = (try? FileManager.default.attributesOfItem(
            atPath: binary.path)[.size] as? Int) ?? -1

        if bundledSize != installedSize {
            try? FileManager.default.removeItem(at: installed)
            try FileManager.default.copyItem(at: bundled, to: installed)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return binary
    }
}
