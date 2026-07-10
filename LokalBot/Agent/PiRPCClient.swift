import Foundation

/// Line-oriented transport a PiRPCClient talks through. PiProcess is the
/// real one; tests inject fakes.
protocol PiLineTransport: Sendable {
    func send(line: String) async throws
    var incoming: AsyncStream<String> { get }
}

// The actor's synchronous `send(line:)` witnesses the async protocol
// requirement (callers hop onto the actor); only `incoming` needs adding.
extension PiProcess: PiLineTransport {
    nonisolated var incoming: AsyncStream<String> { lines }
}

enum PiRPCError: Error {
    case transportClosed
}

/// Correlates pi RPC commands with their `{type:"response", id:…}` acks
/// and fans every other stdout line out as a PiEvent. One consumer loop
/// (started by run()) owns the incoming stream; pending requests are keyed
/// by the id we generated into the command JSON.
actor PiRPCClient {

    private let transport: PiLineTransport
    private var pending: [String: CheckedContinuation<PiResponse, Error>] = [:]
    private var consuming = false
    let events: AsyncStream<PiEvent>
    private let eventContinuation: AsyncStream<PiEvent>.Continuation

    init(transport: PiLineTransport) {
        self.transport = transport
        var continuation: AsyncStream<PiEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func run() {
        guard !consuming else { return }
        consuming = true
        Task { [weak self] in
            guard let self else { return }
            for await line in transport.incoming {
                await self.handle(line: line)
            }
            await self.handleClose()
        }
    }

    func request(_ command: PiCommand) async throws -> PiResponse {
        guard let id = command.id else {
            preconditionFailure("request() needs a command with an id")
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await transport.send(line: command.jsonLine)
                } catch {
                    if let waiting = pending.removeValue(forKey: id) {
                        waiting.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// For extension_ui_response and other lines pi never acks.
    func sendResponse(_ command: PiCommand) async throws {
        try await transport.send(line: command.jsonLine)
    }

    // MARK: - Private

    private func handle(line: String) {
        guard let event = PiEvent.decode(line: line) else { return }
        if case .response(let response) = event,
           let id = response.id,
           let waiting = pending.removeValue(forKey: id) {
            waiting.resume(returning: response)
            return
        }
        eventContinuation.yield(event)
    }

    private func handleClose() {
        for (_, waiting) in pending {
            waiting.resume(throwing: PiRPCError.transportClosed)
        }
        pending.removeAll()
        eventContinuation.finish()
    }
}

extension PiCommand {
    /// The correlation id embedded in this command's JSON, if any.
    var id: String? {
        switch self {
        case .prompt(let id, _, _), .steer(let id, _), .abort(let id),
             .newSession(let id), .getState(let id), .getMessages(let id):
            return id
        case .uiConfirmResponse, .uiCancelResponse:
            return nil   // ui responses correlate to pi's request id, not ours
        }
    }
}
