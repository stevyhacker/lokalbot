import Foundation

/// Line-oriented transport a PiRPCClient talks through. PiProcess is the
/// real one; tests inject fakes.
protocol PiLineTransport: Sendable {
    func send(line: String) async throws
    var incoming: AsyncStream<String> { get }
}

// PiProcess's actor-isolated async `send(line:)` is the protocol witness;
// only `incoming` needs adapting to expose its nonisolated line stream.
extension PiProcess: PiLineTransport {
    nonisolated var incoming: AsyncStream<String> { lines }
}

enum PiRPCError: LocalizedError {
    case transportClosed
    case eventBufferOverflow
    case requestTimedOut(String)
    case duplicateRequestID(String)
    case invalidCommand

    var errorDescription: String? {
        switch self {
        case .transportClosed: "The agent transport closed."
        case .eventBufferOverflow: "The agent event buffer overflowed."
        case .requestTimedOut(let id): "The agent did not acknowledge request \(id) in time."
        case .duplicateRequestID(let id): "Duplicate agent request id: \(id)."
        case .invalidCommand: "An RPC request command did not contain an id."
        }
    }
}

/// Correlates pi RPC commands with their `{type:"response", id:…}` acks
/// and fans every other stdout line out as a PiEvent. One consumer loop
/// (started by run()) owns the incoming stream; pending requests are keyed
/// by the id we generated into the command JSON.
actor PiRPCClient {

    private let transport: PiLineTransport
    private let requestTimeout: Duration
    private struct PendingRequest {
        let continuation: CheckedContinuation<PiResponse, Error>
        let timeoutTask: Task<Void, Never>
    }
    private var pending: [String: PendingRequest] = [:]
    private var consuming = false
    private var terminalError: PiRPCError?
    let events: AsyncStream<PiEvent>
    private let eventContinuation: AsyncStream<PiEvent>.Continuation

    init(
        transport: PiLineTransport,
        requestTimeout: Duration = .seconds(30),
        eventBufferCapacity: Int = 4_096
    ) {
        self.transport = transport
        self.requestTimeout = requestTimeout
        var continuation: AsyncStream<PiEvent>.Continuation!
        events = AsyncStream(
            bufferingPolicy: .bufferingOldest(max(1, eventBufferCapacity))
        ) { continuation = $0 }
        eventContinuation = continuation
    }

    func run() {
        guard !consuming else { return }
        consuming = true
        Task { [weak self] in
            guard let self else { return }
            for await line in self.transport.incoming {
                guard await self.handle(line: line) else { return }
            }
            await self.handleClose()
        }
    }

    func request(_ command: PiCommand) async throws -> PiResponse {
        if let terminalError { throw terminalError }
        guard let id = command.id else {
            throw PiRPCError.invalidCommand
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending[id] == nil else {
                    continuation.resume(throwing: PiRPCError.duplicateRequestID(id))
                    return
                }
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeout = requestTimeout
                let timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.failRequest(id: id, with: PiRPCError.requestTimedOut(id))
                }
                pending[id] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask)
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.transport.send(line: command.jsonLine)
                    } catch {
                        await self.failRequest(id: id, with: error)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.failRequest(id: id, with: CancellationError()) }
        }
    }

    private func failRequest(id: String, with error: Error) {
        guard let waiting = pending.removeValue(forKey: id) else { return }
        waiting.timeoutTask.cancel()
        waiting.continuation.resume(throwing: error)
    }

    private func completeRequest(id: String, with response: PiResponse) {
        guard let waiting = pending.removeValue(forKey: id) else { return }
        waiting.timeoutTask.cancel()
        waiting.continuation.resume(returning: response)
    }

    /// For extension_ui_response and other lines pi never acks.
    func sendResponse(_ command: PiCommand) async throws {
        if let terminalError { throw terminalError }
        try await transport.send(line: command.jsonLine)
    }

    // MARK: - Private

    private func handle(line: String) -> Bool {
        guard let event = PiEvent.decode(line: line) else {
            return emit(.extensionError(
                message: "The agent emitted a malformed RPC frame; it was ignored."))
        }
        if case .response(let response) = event,
           let id = response.id,
           pending[id] != nil {
            completeRequest(id: id, with: response)
            return true
        }
        return emit(event)
    }

    /// The queue keeps its oldest entries so an already-buffered approval can
    /// never be evicted by a burst. Text deltas are the sole lossy event type;
    /// dropping any structural event terminates the stream deterministically.
    private func emit(_ event: PiEvent) -> Bool {
        switch eventContinuation.yield(event) {
        case .enqueued:
            return true
        case .dropped(let droppedEvent):
            guard droppedEvent.isLossyTextDelta else {
                terminateEventStream(with: PiRPCError.eventBufferOverflow)
                return false
            }
            return true
        case .terminated:
            terminateEventStream(with: PiRPCError.transportClosed)
            return false
        @unknown default:
            terminateEventStream(with: PiRPCError.eventBufferOverflow)
            return false
        }
    }

    private func handleClose() {
        terminateEventStream(with: PiRPCError.transportClosed)
    }

    private func terminateEventStream(with error: PiRPCError) {
        guard terminalError == nil else { return }
        terminalError = error
        failPendingRequests(with: error)
        eventContinuation.finish()
    }

    private func failPendingRequests(with error: Error) {
        for (_, waiting) in pending {
            waiting.timeoutTask.cancel()
            waiting.continuation.resume(throwing: error)
        }
        pending.removeAll()
    }
}

private extension PiEvent {
    var isLossyTextDelta: Bool {
        if case .messageUpdate(.textDelta) = self { return true }
        return false
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
