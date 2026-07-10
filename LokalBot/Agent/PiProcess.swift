import Foundation

enum PiProcessError: Error {
    case executableNotFound(String)
    case notRunning
}

/// Owns one pi subprocess: spawns it from a PiLaunchPlan, feeds stdout
/// bytes through PiJSONLFrameSplitter (LF-only framing — see the splitter's
/// doc comment), exposes complete frames as an AsyncStream, and supervises
/// shutdown (SIGTERM → 2s grace → SIGKILL). Mirrors the Process-handling
/// approach in LlamaServer, as an actor because send/stop race with the
/// termination handler.
actor PiProcess {

    private let plan: PiLaunchPlan
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var splitter = PiJSONLFrameSplitter()
    private var linesContinuation: AsyncStream<String>.Continuation?
    private var started = false
    private var exited = false
    private(set) var stderrTail: [String] = []

    let lines: AsyncStream<String>

    init(plan: PiLaunchPlan) {
        self.plan = plan
        var continuation: AsyncStream<String>.Continuation!
        lines = AsyncStream { continuation = $0 }
        linesContinuation = continuation
    }

    var isRunning: Bool { started && !exited }

    func start() throws {
        guard FileManager.default.isExecutableFile(atPath: plan.executable.path) else {
            throw PiProcessError.executableNotFound(plan.executable.path)
        }
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { [weak self] in await self?.consumeStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { [weak self] in await self?.consumeStderr(text) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { [weak self] in await self?.handleExit() }
        }
        try process.run()
        started = true
    }

    func send(line: String) throws {
        guard isRunning else { throw PiProcessError.notRunning }
        let payload = Data((line + "\n").utf8)
        try stdinPipe.fileHandleForWriting.write(contentsOf: payload)
    }

    func stop() async {
        guard isRunning else { return }
        process.terminate()
        for _ in 0..<20 where process.isRunning {   // 2s grace
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        handleExit()
    }

    // MARK: - Private

    private func consumeStdout(_ data: Data) {
        if data.isEmpty {   // EOF
            if let last = splitter.flush() { linesContinuation?.yield(last) }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            return
        }
        for frame in splitter.append(data) {
            linesContinuation?.yield(frame)
        }
    }

    private func consumeStderr(_ text: String) {
        stderrTail.append(contentsOf: text.split(separator: "\n").map(String.init))
        if stderrTail.count > 50 { stderrTail.removeFirst(stderrTail.count - 50) }
    }

    private func handleExit() {
        guard !exited else { return }
        exited = true
        if let last = splitter.flush() { linesContinuation?.yield(last) }
        linesContinuation?.finish()
        linesContinuation = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
    }
}
