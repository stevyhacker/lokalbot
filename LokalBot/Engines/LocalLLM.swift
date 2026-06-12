import Foundation
import Darwin

/// Built-in LLM backend: a bundled llama.cpp `llama-server` (Metal) speaking
/// the OpenAI-compatible API on localhost. The small default model ships
/// inside the app; bigger ones download on demand (Handy-style catalog).
/// No Ollama / LM Studio / anything required.

// MARK: - Catalog

struct ModelCatalog {

    struct Entry: Identifiable, Hashable {
        let id: String
        let displayName: String
        let fileName: String
        let url: String
        let sizeGB: Double
        let blurb: String
        /// Qwen3 (non-2507) thinks by default; we turn that off for summaries.
        let disablesThinking: Bool
        var isBundled: Bool { id == ModelCatalog.bundledID }
    }

    static let bundledID = "qwen3.5-0.8b"

    /// Five recommended models, smallest first. Current generations
    /// (Qwen3.5, Gemma 4) verified June 2026 — same families Cotabby ships.
    static let entries: [Entry] = [
        Entry(id: bundledID, displayName: "Qwen3.5 0.8B (built-in)",
              fileName: "Qwen3.5-0.8B-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf",
              sizeGB: 0.53, blurb: "Ships with the app. Fast, fine for short meetings.",
              disablesThinking: true),
        Entry(id: "qwen3.5-2b", displayName: "Qwen3.5 2B",
              fileName: "Qwen3.5-2B-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf",
              sizeGB: 1.28, blurb: "Best quality under 1.5 GB. Any Apple Silicon Mac.",
              disablesThinking: true),
        Entry(id: "gemma4-e4b", displayName: "Gemma 4 E4B",
              fileName: "gemma-4-E4B-it-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf",
              sizeGB: 4.98, blurb: "Edge-optimized (MatFormer). 16 GB Macs.",
              disablesThinking: false),
        Entry(id: "lfm2.5-8b-a1b", displayName: "LFM2.5 8B (MoE)",
              fileName: "LFM2.5-8B-A1B-Q4_K_M.gguf",
              url: "https://huggingface.co/LiquidAI/LFM2.5-8B-A1B-GGUF/resolve/main/LFM2.5-8B-A1B-Q4_K_M.gguf",
              sizeGB: 5.16, blurb: "Liquid AI MoE — ~1B active, extremely fast. 16 GB Macs.",
              disablesThinking: false),
        Entry(id: "qwen3.5-9b", displayName: "Qwen3.5 9B",
              fileName: "Qwen3.5-9B-Q6_K.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q6_K.gguf",
              sizeGB: 7.46, blurb: "Flagship small model, near-lossless Q6_K. 16 GB+ Macs.",
              disablesThinking: true),
        Entry(id: "qwen3.6-35b-a3b", displayName: "Qwen3.6 35B (MoE)",
              fileName: "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf",
              sizeGB: 17.73, blurb: "Newest generation; 35B quality, ~3B active. 32 GB+ Macs.",
              disablesThinking: true),
    ]

    static func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    /// Bundled model lives in Resources; downloads live in <storage>/models/.
    static func localURL(for entry: Entry, storage: StorageManager) -> URL? {
        if entry.isBundled,
           let bundled = Bundle.main.resourceURL?
               .appendingPathComponent("llama-models/\(entry.fileName)"),
           ModelFileValidator.looksLikeGGUF(bundled) {
            return bundled
        }
        let downloaded = storage.rootURL.appendingPathComponent("models/\(entry.fileName)")
        return ModelFileValidator.looksLikeGGUF(downloaded) ? downloaded : nil
    }
}

enum ModelFileValidator {
    static func looksLikeGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }
}

// MARK: - Download manager

@MainActor
final class ModelDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {

    static let shared = ModelDownloadManager()

    @Published private(set) var progress: [String: Double] = [:]   // entry id → 0…1
    @Published private(set) var errors: [String: String] = [:]

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var destinations: [Int: (id: String, url: URL)] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self,
                                          delegateQueue: .main)

    func download(_ entry: ModelCatalog.Entry, storage: StorageManager) {
        guard tasks[entry.id] == nil, let url = URL(string: entry.url) else { return }
        let folder = storage.rootURL.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let task = session.downloadTask(with: url)
        destinations[task.taskIdentifier] = (entry.id, folder.appendingPathComponent(entry.fileName))
        tasks[entry.id] = task
        progress[entry.id] = 0
        errors[entry.id] = nil
        task.resume()
    }

    func cancel(_ entry: ModelCatalog.Entry) {
        tasks[entry.id]?.cancel()
        tasks[entry.id] = nil
        progress[entry.id] = nil
    }

    func delete(_ entry: ModelCatalog.Entry, storage: StorageManager) {
        guard !entry.isBundled else { return }
        try? FileManager.default.removeItem(
            at: storage.rootURL.appendingPathComponent("models/\(entry.fileName)"))
        objectWillChange.send()
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        let taskID = downloadTask.taskIdentifier
        Task { @MainActor in
            if let (id, _) = destinations[taskID] { progress[id] = fraction }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // Move synchronously — `location` is deleted when this returns.
        let taskID = downloadTask.taskIdentifier
        guard let http = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            Task { @MainActor in
                fail(taskID: taskID, message: "Download failed (HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)).")
            }
            return
        }
        let moved = (try? FileManager.default.url(for: .itemReplacementDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: location, create: true))
            .map { $0.appendingPathComponent(location.lastPathComponent) }
        var stash: URL?
        if let moved { stash = (try? FileManager.default.moveItem(at: location, to: moved)) != nil ? moved : nil }
        Task { @MainActor in
            defer { tasks = tasks.filter { $0.value.taskIdentifier != taskID } }
            guard let (id, destination) = destinations[taskID] else { return }
            destinations[taskID] = nil
            progress[id] = nil
            guard let stash else { errors[id] = "Download failed (could not stage file)."; return }
            guard ModelFileValidator.looksLikeGGUF(stash) else {
                try? FileManager.default.removeItem(at: stash)
                errors[id] = "Download failed (response was not a GGUF model)."
                return
            }
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: stash, to: destination)
            } catch {
                errors[id] = "Could not save model: \(error.localizedDescription)"
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        let taskID = task.taskIdentifier
        Task { @MainActor in
            fail(taskID: taskID, message: error.localizedDescription)
        }
    }

    private func fail(taskID: Int, message: String) {
        if let (id, _) = destinations[taskID] {
            errors[id] = message
            progress[id] = nil
            destinations[taskID] = nil
            tasks[id] = nil
        }
    }
}

// MARK: - llama-server lifecycle

/// Owns the bundled llama-server subprocess. One model loaded at a time;
/// switching models restarts the server. Stopped when the app quits.
actor LlamaServer {

    /// Chat/completions instance (summaries, digests, Q&A).
    static let shared = LlamaServer(port: 17872, extraArgs: [])
    /// Embeddings instance (semantic search) — small model, second port.
    static let embedder = LlamaServer(port: 17873,
                                      extraArgs: ["--embeddings", "--pooling", "mean"])

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
