import Foundation
import Darwin

/// Built-in LLM backend, part 3 of 3: the bundled llama-server subprocess
/// lifecycle. One model loaded at a time; switching models restarts the server.
/// Stopped when the app quits.
actor LlamaServer {

    /// Chat/completions instance (summaries, digests, Q&A).
    static let shared = LlamaServer(port: 17872, contextTokens: 16_384, extraArgs: [])
    /// Embeddings instance (semantic search) — small model, second port.
    static let embedder = LlamaServer(port: 17873, contextTokens: 2_048,
                                      extraArgs: ["--embeddings", "--pooling", "mean"])
    /// Cotyping instance — an optional separate (typically smaller/faster)
    /// model on a third port, so inline suggestions never contend with the
    /// summarizer for the shared server (no model-reload thrash).
    static let cotyping = LlamaServer(port: 17874, contextTokens: 2_048, extraArgs: [])

    nonisolated let port: Int
    nonisolated let contextTokens: Int
    private let extraArgs: [String]
    nonisolated var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    init(port: Int, contextTokens: Int, extraArgs: [String]) {
        self.port = port
        self.contextTokens = contextTokens
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
           await healthy(), await healthyServingExpectedConfiguration(modelAt: url) {
            return
        }
        if await healthyServingExpectedConfiguration(modelAt: url) {
            loadedModelPath = url.path
            return
        }
        try await start(modelAt: url)
    }

    private func start(modelAt url: URL) async throws {
        await stop()
        let binary = try installedBinary()
        if await healthyServingExpectedConfiguration(modelAt: url) {
            loadedModelPath = url.path
            return
        }
        if await healthy() {
            await stopRecordedServerIfOwned(expectedBinary: binary)
            if await healthyServingExpectedConfiguration(modelAt: url) {
                loadedModelPath = url.path
                return
            }
        }
        // A llama-server orphaned by a prior run (children outlive a hard quit)
        // or an older app generation sharing these private ports may still hold
        // this one without a marker we own. Reclaim it, then re-check.
        if await healthy() {
            await Self.reclaimStaleLlamaServer(onPort: port)
        }
        guard !(await healthy()) else {
            throw ServerError.failedToStart(
                "port \(port) is held by another process that is not a llama-server; free it and try again")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "-m", url.path,
            "--host", "127.0.0.1", "--port", String(port),
            "-c", String(contextTokens),
            "-ngl", "99",           // full Metal offload
            "--jinja",              // correct chat templates (qwen3, gpt-oss)
            "--no-webui",
        ] + extraArgs
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        loadedModelPath = url.path
        writePidMarker(ServerPidMarker(
            pid: process.processIdentifier,
            port: port,
            binaryPath: binary.path,
            modelPath: url.path,
            contextTokens: contextTokens,
            extraArgs: extraArgs))

        // Model load can take a while for the big ones; poll /health.
        for _ in 0..<240 {
            try await Task.sleep(for: .milliseconds(500))
            if !process.isRunning {
                throw ServerError.failedToStart("llama-server exited during startup")
            }
            if await healthy() { return }
        }
        await stop()
        throw ServerError.failedToStart("server did not become healthy in time")
    }

    func stop() async {
        let old = process
        process = nil
        loadedModelPath = nil
        guard let old else { return }
        removePidMarker()
        guard old.isRunning else { return }
        old.terminate()
        for _ in 0..<40 {
            if !old.isRunning { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if old.isRunning {
            kill(old.processIdentifier, SIGKILL)
        }
    }

    private func stopRecordedServerIfOwned(expectedBinary: URL) async {
        guard let marker = readPidMarker(), marker.port == port else {
            removePidMarker()
            return
        }
        let pid = marker.pid
        guard kill(pid, 0) == 0 else {
            removePidMarker()
            return
        }
        guard marker.binaryPath == expectedBinary.path,
              Self.processPath(for: pid) == expectedBinary.path else {
            removePidMarker()
            return
        }
        kill(pid, SIGTERM)
        for _ in 0..<40 {
            if kill(pid, 0) != 0 {
                removePidMarker()
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        removePidMarker()
    }

    private func readPidMarker() -> ServerPidMarker? {
        guard let data = try? Data(contentsOf: pidMarkerURL) else { return nil }
        return try? JSONDecoder().decode(ServerPidMarker.self, from: data)
    }

    private func writePidMarker(_ marker: ServerPidMarker) {
        do {
            try FileManager.default.createDirectory(
                at: pidMarkerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(marker)
            try data.write(to: pidMarkerURL, options: .atomic)
        } catch {
            // Best-effort orphan recovery only; startup must not depend on it.
        }
    }

    private func removePidMarker() {
        try? FileManager.default.removeItem(at: pidMarkerURL)
    }

    private var pidMarkerURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppIdentifiers.bundleID, isDirectory: true)
        return appSupport.appendingPathComponent("llama-server-\(port).pid.json")
    }

    private func healthy() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func healthyServing(modelAt url: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return Self.servedModelNames(from: data).contains(Self.modelMatchKey(for: url))
    }

    private func healthyServingExpectedConfiguration(modelAt url: URL) async -> Bool {
        guard await healthyServing(modelAt: url),
              let marker = readPidMarker(),
              marker.port == port,
              marker.modelPath == url.path,
              marker.contextTokens == Optional(contextTokens),
              marker.extraArgs == Optional(extraArgs),
              kill(marker.pid, 0) == 0,
              Self.processPath(for: marker.pid) == marker.binaryPath
        else { return false }
        return true
    }

    nonisolated static func modelMatchKey(for url: URL) -> String {
        url.lastPathComponent
    }

    nonisolated static func servedModelNames(from data: Data) -> Set<String> {
        guard let payload = try? JSONDecoder().decode(ModelListPayload.self, from: data) else { return [] }
        var names = Set<String>()
        for model in payload.models ?? [] {
            if let name = model.name, !name.isEmpty { names.insert(name) }
            if let model = model.model, !model.isEmpty { names.insert(model) }
        }
        for model in payload.data ?? [] {
            if let id = model.id, !id.isEmpty { names.insert(id) }
        }
        return names
    }

    nonisolated static func processPath(for pid: pid_t) -> String? {
        let bufferSize = 4096
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(bufferSize))
        }
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Frees `port` when a stale `llama-server` is squatting on it — our own
    /// orphan after a hard quit, or an older app generation that shares these
    /// private ports. Only processes whose executable is a `llama-server` are
    /// killed, so an unrelated listener still surfaces as a startup error.
    nonisolated static func reclaimStaleLlamaServer(onPort port: Int) async {
        let pids = listeningPIDs(onPort: port).filter {
            processPath(for: $0)?.hasSuffix("/llama-server") == true
        }
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }
        for _ in 0..<40 {
            if pids.allSatisfy({ kill($0, 0) != 0 }) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// PIDs listening on `port`, via `lsof` (best-effort; empty if unavailable).
    nonisolated static func listeningPIDs(onPort port: Int) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { pid_t($0) }
    }

    private struct ServerPidMarker: Codable {
        var pid: pid_t
        var port: Int
        var binaryPath: String
        var modelPath: String
        var contextTokens: Int?
        var extraArgs: [String]?
    }

    private struct ModelListPayload: Decodable {
        var models: [ListedModel]?
        var data: [ListedModel]?
    }

    private struct ListedModel: Decodable {
        var id: String?
        var name: String?
        var model: String?
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
