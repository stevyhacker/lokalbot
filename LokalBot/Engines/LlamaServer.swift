import Foundation
import Darwin

/// Built-in LLM backend, part 3 of 3: the bundled llama-server subprocess
/// lifecycle. One model loaded at a time; switching models restarts the server.
/// Stopped when the app quits.
actor LlamaServer {

    /// Chat/completions instance (summaries, digests, Q&A).
    static let shared = LlamaServer(
        port: 17872, contextTokens: 16_384,
        extraArgs: ["--cache-ram", "2048"],
        runtimeAllowanceBytes: 3 * 1_073_741_824)
    /// Embeddings instance (semantic search) — small model, second port.
    static let embedder = LlamaServer(port: 17873, contextTokens: 2_048,
                                      extraArgs: ["--embeddings", "--pooling", "mean",
                                                  "--parallel", "1", "--cache-ram", "256"],
                                      runtimeAllowanceBytes: 384 * 1_048_576)
    /// Cotyping instance — an optional separate (typically smaller/faster)
    /// model on a third port, so inline suggestions never contend with the
    /// summarizer for the shared server (no model-reload thrash).
    static let cotyping = LlamaServer(
        port: 17874, contextTokens: 2_048,
        extraArgs: ["--parallel", "1", "--cache-ram", "512"],
        runtimeAllowanceBytes: 768 * 1_048_576)

    nonisolated let port: Int
    nonisolated let contextTokens: Int
    private let extraArgs: [String]
    private let runtimeAllowanceBytes: Int64
    nonisolated var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    init(port: Int, contextTokens: Int, extraArgs: [String],
         runtimeAllowanceBytes: Int64 = 512 * 1_048_576) {
        self.port = port
        self.contextTokens = contextTokens
        self.extraArgs = extraArgs
        self.runtimeAllowanceBytes = runtimeAllowanceBytes
    }

    private var process: Process?
    private var loadedModelPath: String?
    private var loadedAuthenticationToken: String?
    private var residencyGeneration: UUID?
    private let startup = AsyncSingleFlight()

    /// Shared bearer required by this private localhost server. It is created
    /// with 256 bits of randomness, stored mode 0600, and can be obtained
    /// before the lazy server boot so leased engines carry the right header.
    func authenticationToken() -> String {
        if let loadedAuthenticationToken { return loadedAuthenticationToken }
        if let markerToken = readPidMarker()?.authenticationToken {
            loadedAuthenticationToken = markerToken
            persistAuthenticationToken(markerToken)
            return markerToken
        }
        if let data = try? Data(contentsOf: authenticationTokenURL),
           let saved = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           saved.count >= 32 {
            loadedAuthenticationToken = saved
            return saved
        }
        let created = Self.makeAuthenticationToken()
        loadedAuthenticationToken = created
        persistAuthenticationToken(created)
        return created
    }

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
        while true {
            if let process, process.isRunning, loadedModelPath == url.path,
               await healthy(), await healthyServingExpectedConfiguration(modelAt: url) {
                await registerResidency(modelAt: url)
                return
            }
            try await startup.run { [weak self] in
                guard let self else {
                    throw ServerError.failedToStart("server was released during startup")
                }
                try await self.ensureRunningOnce(modelAt: url)
            }
            // A caller for a different model may have owned the flight we just
            // awaited. Loop so this request starts one replacement flight;
            // callers for the same model return together without duplicate
            // subprocess starts or health polling.
            guard loadedModelPath == url.path else { continue }
            await registerResidency(modelAt: url)
            return
        }
    }

    private func ensureRunningOnce(modelAt url: URL) async throws {
        if let process, process.isRunning, loadedModelPath == url.path,
           await healthy(), await healthyServingExpectedConfiguration(modelAt: url) {
            return
        }
        if await healthyServingExpectedConfiguration(modelAt: url) {
            loadedModelPath = url.path
            loadedAuthenticationToken = readPidMarker()?.authenticationToken
            return
        }
        try await start(modelAt: url)
    }

    /// This server's row in the app-wide model-memory ledger. Adopted healthy
    /// servers register too — their weights are just as resident as ours.
    private nonisolated var residencyID: String { "llama-server:\(port)" }

    private func registerResidency(modelAt url: URL) async {
        // Diagnostics must never gate inference. When libproc cannot provide a
        // stable process identity, retain the model row with its weight-size
        // estimate and let a later successful registration add live telemetry.
        let identity = activeProcessIdentity(modelAt: url)
        let generation = UUID()
        residencyGeneration = generation
        await ModelResidency.shared.register(
            id: residencyID,
            label: url.lastPathComponent,
            bytes: estimatedResidentBytes(modelAt: url),
            processIdentifier: identity?.processIdentifier,
            processStartTime: identity?.startTime,
            generation: generation,
            unload: { [weak self] in await self?.stop() })
    }

    private func activeProcessIdentity(
        modelAt url: URL
    ) -> SystemResourceSampler.ProcessIdentity? {
        if let process, process.isRunning,
           loadedModelPath == url.path,
           let usage = SystemResourceSampler.processUsage(for: process.processIdentifier) {
            return usage.identity
        }
        // A healthy server from a prior app process is adopted through its
        // validated marker and is no longer in our child tree.
        guard let marker = readPidMarker(),
              marker.port == port,
              marker.modelPath == url.path,
              marker.contextTokens == Optional(contextTokens),
              marker.extraArgs == Optional(extraArgs),
              kill(marker.pid, 0) == 0,
              Self.processPath(for: marker.pid) == marker.binaryPath,
              let usage = SystemResourceSampler.processUsage(for: marker.pid)
        else { return nil }
        return usage.identity
    }

    private func start(modelAt url: URL) async throws {
        await stop()
        let binary = try installedBinary()
        if await healthyServingExpectedConfiguration(modelAt: url) {
            loadedModelPath = url.path
            loadedAuthenticationToken = readPidMarker()?.authenticationToken
            return
        }
        if await healthy() {
            await stopRecordedServerIfOwned(expectedBinary: binary)
            if await healthyServingExpectedConfiguration(modelAt: url) {
                loadedModelPath = url.path
                loadedAuthenticationToken = readPidMarker()?.authenticationToken
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
        // Make room before the subprocess mmaps the weights: evict the
        // least-recently-used other models if this one would bust the budget.
        let nonEvictableBytes = await ModelRuntimeRegistry.shared.totalEstimatedBytes
        let loadReservation = await ModelResidency.shared.willLoad(
            id: residencyID,
            bytes: estimatedResidentBytes(modelAt: url),
            reservedBytes: Int64(clamping: nonEvictableBytes))
        do {
            let authenticationToken = authenticationToken()
            let process = Process()
            process.executableURL = binary
            process.arguments = [
                "-m", url.path,
                "--host", "127.0.0.1", "--port", String(port),
                "-c", String(contextTokens),
                "-ngl", "99",           // full Metal offload
                "--jinja",              // correct chat templates (qwen3, gpt-oss)
                "--no-webui",
                "--api-key", authenticationToken,
            ] + extraArgs
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                let processIdentifier = process.processIdentifier
                Task { await self?.processDidTerminate(processIdentifier) }
            }
            try process.run()
            self.process = process
            loadedModelPath = url.path
            loadedAuthenticationToken = authenticationToken
            writePidMarker(LocalLlamaServerMarker(
                pid: process.processIdentifier,
                port: port,
                binaryPath: binary.path,
                modelPath: url.path,
                contextTokens: contextTokens,
                extraArgs: extraArgs,
                authenticationToken: authenticationToken))

            // Model load can take a while for the big ones; poll /health.
            for _ in 0..<240 {
                try await Task.sleep(for: .milliseconds(500))
                if !process.isRunning {
                    throw ServerError.failedToStart("llama-server exited during startup")
                }
                if await healthy() { return }
            }
            throw ServerError.failedToStart("server did not become healthy in time")
        } catch {
            await ModelResidency.shared.cancelLoad(loadReservation)
            await stop()
            throw error
        }
    }

    /// Weight files are not the whole llama footprint: prompt cache, KV, and
    /// multimodal projector allocations can be several GiB. Keep an explicit
    /// per-role allowance and include any `--mmproj` file in admission.
    private func estimatedResidentBytes(modelAt url: URL) -> Int64 {
        var total = ModelResidency.weightBytes(at: url)
        if let projectorFlag = extraArgs.firstIndex(of: "--mmproj"),
           extraArgs.indices.contains(projectorFlag + 1) {
            total = Self.saturatingAdd(
                total,
                ModelResidency.weightBytes(
                    at: URL(fileURLWithPath: extraArgs[projectorFlag + 1])))
        }
        return Self.saturatingAdd(total, max(0, runtimeAllowanceBytes))
    }

    private nonisolated static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    func stop() async {
        let old = process
        let generation = residencyGeneration
        process = nil
        loadedModelPath = nil
        loadedAuthenticationToken = nil
        residencyGeneration = nil
        if let old {
            removePidMarker(ifMatching: old.processIdentifier)
            if old.isRunning {
                old.terminate()
                for _ in 0..<40 {
                    if !old.isRunning { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if old.isRunning {
                    kill(old.processIdentifier, SIGKILL)
                }
            }
        } else {
            // A healthy server can be adopted from a previous app process. It
            // has a validated PID marker but no Foundation `Process` handle;
            // still terminate it so eviction and the resource ledger reflect
            // real memory residency instead of only hiding the row.
            if let expectedBinary = try? installedBinary() {
                await stopRecordedServerIfOwned(expectedBinary: expectedBinary)
            }
        }
        if let generation {
            await ModelResidency.shared.unregister(
                id: residencyID,
                ifGenerationMatches: generation)
        }
    }

    private func processDidTerminate(_ processIdentifier: pid_t) async {
        guard process?.processIdentifier == processIdentifier else { return }
        let generation = residencyGeneration
        process = nil
        loadedModelPath = nil
        loadedAuthenticationToken = nil
        residencyGeneration = nil
        removePidMarker(ifMatching: processIdentifier)
        if let generation {
            await ModelResidency.shared.unregister(
                id: residencyID,
                ifGenerationMatches: generation)
        }
    }

    private func stopRecordedServerIfOwned(expectedBinary: URL) async {
        guard let marker = readPidMarker() else { return }
        let pid = marker.pid
        guard marker.port == port else {
            removePidMarker(ifMatching: pid)
            return
        }
        guard kill(pid, 0) == 0 else {
            removePidMarker(ifMatching: pid)
            return
        }
        guard marker.binaryPath == expectedBinary.path,
              Self.processPath(for: pid) == expectedBinary.path else {
            removePidMarker(ifMatching: pid)
            return
        }
        kill(pid, SIGTERM)
        for _ in 0..<40 {
            if kill(pid, 0) != 0 {
                removePidMarker(ifMatching: pid)
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        removePidMarker(ifMatching: pid)
    }

    private func readPidMarker() -> LocalLlamaServerMarker? {
        guard let data = try? Data(contentsOf: pidMarkerURL) else { return nil }
        return try? JSONDecoder().decode(LocalLlamaServerMarker.self, from: data)
    }

    private func writePidMarker(_ marker: LocalLlamaServerMarker) {
        do {
            try FileManager.default.createDirectory(
                at: pidMarkerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(marker)
            try data.write(to: pidMarkerURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: pidMarkerURL.path)
        } catch {
            // Best-effort orphan recovery only; startup must not depend on it.
        }
    }

    private func removePidMarker(ifMatching processIdentifier: pid_t) {
        guard readPidMarker()?.pid == processIdentifier else { return }
        try? FileManager.default.removeItem(at: pidMarkerURL)
    }

    private var pidMarkerURL: URL {
        LocalLlamaServerAuthentication.markerURL(port: port)
    }

    private var authenticationTokenURL: URL {
        AppDirectories.applicationSupport
            .appendingPathComponent("llama-server-\(port).auth-token")
    }

    private func persistAuthenticationToken(_ token: String) {
        do {
            try FileManager.default.createDirectory(
                at: authenticationTokenURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(token.utf8).write(to: authenticationTokenURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: authenticationTokenURL.path)
        } catch {
            lokalbotLog("llama-server: could not persist localhost authentication token")
        }
    }

    private func healthy() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        if let token = loadedAuthenticationToken ?? readPidMarker()?.authenticationToken {
            LocalLlamaServerAuthentication.apply(to: &request, token: token)
        }
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func healthyServing(modelAt url: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        guard let token = loadedAuthenticationToken ?? readPidMarker()?.authenticationToken else {
            return false
        }
        LocalLlamaServerAuthentication.apply(to: &request, token: token)
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

    private nonisolated static func makeAuthenticationToken() -> String {
        (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
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

        let installed = AppDirectories.applicationSupport
            .appendingPathComponent("llama-cpp", isDirectory: true)
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
