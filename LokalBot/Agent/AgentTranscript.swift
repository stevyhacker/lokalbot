import Foundation

enum AgentToolStatus: Equatable {
    case running, succeeded, failed
}

/// App-owned, structured description of a mutating tool request. Keeping the
/// fields separate lets the approval surface show the exact command/content
/// instead of trusting a model-authored one-line summary.
struct AgentApprovalRequest: Equatable, Identifiable {
    struct Edit: Equatable {
        let oldText: String
        let newText: String
    }

    let id: String
    let tool: String
    let workspace: String?
    let path: String?
    let command: String?
    let content: String?
    let edits: [Edit]
    let summary: String?
    let isTruncated: Bool

    var hasStructuredDetails: Bool {
        workspace != nil || path != nil || command != nil || content != nil || !edits.isEmpty
    }
}

enum AgentTranscriptItem: Equatable, Identifiable {
    case user(id: String, text: String)
    case assistant(id: String, text: String, isStreaming: Bool)
    case tool(id: String, name: String, argsJSON: String, output: String, status: AgentToolStatus)
    case approval(AgentApprovalRequest)
    case notice(id: String, text: String, isError: Bool)

    var id: String {
        switch self {
        case .user(let id, _), .assistant(let id, _, _), .tool(let id, _, _, _, _),
             .notice(let id, _, _):
            return id
        case .approval(let request):
            return request.id
        }
    }
}

/// Folds the PiEvent stream into a display-ready transcript. Pure state
/// machine — no async, no UI — so every folding rule is unit-testable
/// (same decomposition philosophy as the Cotyping policy types).
struct AgentTranscriptFolder: Equatable {
    private(set) var items: [AgentTranscriptItem] = []
    private(set) var isAgentRunning = false
    private var streamingAssistantID: String?
    private var counter = 0

    /// Resolved fresh on every use so removals elsewhere in the array
    /// (e.g. resolveApproval) can never leave a stale index behind.
    private var streamingAssistantIndex: Int? {
        guard let streamingAssistantID else { return nil }
        return items.firstIndex { $0.id == streamingAssistantID }
    }

    // MARK: - Local inserts (not driven by pi events)

    mutating func noteUserPrompt(_ text: String) {
        items.append(.user(id: nextID("user"), text: text))
    }

    mutating func appendAssistantMessage(_ text: String) {
        items.append(.assistant(id: nextID("assistant"), text: text, isStreaming: false))
    }

    mutating func appendNotice(_ text: String, isError: Bool = false) {
        items.append(.notice(id: nextID("notice"), text: text, isError: isError))
    }

    mutating func addApproval(_ request: AgentApprovalRequest) {
        items.append(.approval(request))
    }

    mutating func resolveApproval(requestID: String) {
        items.removeAll {
            if case .approval(let request) = $0 { return request.id == requestID }
            return false
        }
    }

    // MARK: - Event folding

    mutating func fold(_ event: PiEvent) {
        switch event {
        case .agentStart:
            isAgentRunning = true
        case .agentSettled:
            isAgentRunning = false
            finishStreamingAssistant()
        case .messageStart(let role):
            guard role == "assistant" else { return }
            let id = nextID("assistant")
            items.append(.assistant(id: id, text: "", isStreaming: true))
            streamingAssistantID = id
        case .messageUpdate(.textDelta(let delta)):
            appendToStreamingAssistant(delta)
        case .messageEnd(let role, let text):
            guard role == "assistant" else { return }
            defer { streamingAssistantID = nil }
            if let index = streamingAssistantIndex,
               case .assistant(let id, let streamed, _) = items[index] {
                let final = text.isEmpty ? streamed : text
                if final.isEmpty {
                    items.remove(at: index)   // tool-call-only turn: drop the empty bubble
                } else {
                    items[index] = .assistant(id: id, text: final, isStreaming: false)
                }
            } else if !text.isEmpty {
                items.append(.assistant(id: nextID("assistant"), text: text, isStreaming: false))
            }
        case .toolExecutionStart(let callID, let name, let argsJSON):
            items.append(.tool(id: callID, name: name, argsJSON: argsJSON, output: "", status: .running))
        case .toolExecutionUpdate(let callID, let output):
            updateTool(callID) { _, _ in (output, .running) }
        case .toolExecutionEnd(let callID, let output, let isError):
            updateTool(callID) { _, _ in (output, isError ? .failed : .succeeded) }
        case .extensionError(let message):
            appendNotice(message, isError: true)
        case .agentEnd, .messageUpdate, .response, .extensionUIRequest, .unknown:
            break
        }
    }

    // MARK: - Helpers

    private mutating func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(counter)"
    }

    private mutating func appendToStreamingAssistant(_ delta: String) {
        if streamingAssistantIndex == nil {
            let id = nextID("assistant")
            items.append(.assistant(id: id, text: "", isStreaming: true))
            streamingAssistantID = id
        }
        if let index = streamingAssistantIndex,
           case .assistant(let id, let text, _) = items[index] {
            items[index] = .assistant(id: id, text: text + delta, isStreaming: true)
        }
    }

    private mutating func finishStreamingAssistant() {
        defer { streamingAssistantID = nil }
        guard let index = streamingAssistantIndex,
              case .assistant(let id, let text, _) = items[index] else { return }
        if text.isEmpty {
            items.remove(at: index)
        } else {
            items[index] = .assistant(id: id, text: text, isStreaming: false)
        }
    }

    private mutating func updateTool(_ callID: String,
                                     _ transform: (String, AgentToolStatus) -> (String, AgentToolStatus)) {
        guard let index = items.firstIndex(where: { $0.id == callID }),
              case .tool(let id, let name, let args, let output, let status) = items[index] else { return }
        let (newOutput, newStatus) = transform(output, status)
        items[index] = .tool(id: id, name: name, argsJSON: args, output: newOutput, status: newStatus)
    }
}
