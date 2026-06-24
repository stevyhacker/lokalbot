import Combine
import Foundation

/// One line in the chat transcript. `activity` holds the tool steps the
/// assistant ran for this turn (shown as chips above its answer).
struct ChatMessage: Identifiable, Equatable {
    struct Activity: Identifiable, Equatable {
        let id = UUID()
        let tool: String
        let icon: String
        var text: String
        var done: Bool
    }

    let id = UUID()
    let role: ChatRole
    var text: String
    var activity: [Activity] = []
    /// The assistant turn is still being generated.
    var isPending = false
    /// The turn failed (engine unreachable, no model, …) — rendered as an error.
    var isError = false
}

/// Drives the Chat section: owns the message list and runs `ChatAgent` against
/// the same `TextEngine` the summariser uses (resolved lazily per send via
/// `ProcessingPipeline.makeTextEngine`, so it always reflects the current
/// Settings → Models choice and boots the built-in server on first use).
@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published private(set) var isResponding = false

    /// Prompt chips shown on the empty state.
    let suggestions = [
        "What did we decide in my last meeting?",
        "List my recent meetings",
        "Search my meetings for action items",
    ]

    private let makeEngine: () async throws -> TextEngine
    private let tools: ChatToolRunner
    private var task: Task<Void, Never>?

    init(makeEngine: @escaping () async throws -> TextEngine, tools: ChatToolRunner) {
        self.makeEngine = makeEngine
        self.tools = tools
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isResponding
    }

    /// Send the current draft (or an explicit `prompt`, e.g. a suggestion chip).
    func send(_ prompt: String? = nil) {
        let text = (prompt ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        draft = ""

        // History = finalised turns only (skip the pending/error placeholders).
        let history = messages
            .filter { !$0.isPending && !$0.isError }
            .map { ChatAgent.Turn(role: $0.role, text: $0.text) }

        messages.append(ChatMessage(role: .user, text: text))
        let assistant = ChatMessage(role: .assistant, text: "", isPending: true)
        let assistantID = assistant.id
        messages.append(assistant)
        isResponding = true

        task = Task { [weak self] in
            await self?.run(latest: text, history: history, assistantID: assistantID)
        }
    }

    /// Cancel an in-flight response.
    func stop() { task?.cancel() }

    /// Start a fresh conversation.
    func clear() {
        task?.cancel()
        task = nil
        messages.removeAll()
        isResponding = false
    }

    // MARK: - Run

    private func run(latest: String, history: [ChatAgent.Turn], assistantID: UUID) async {
        defer { isResponding = false }
        do {
            let engine = try await makeEngine()
            let agent = ChatAgent(engine: engine, runner: tools)
            let answer = try await agent.respond(history: history, latest: latest) { [weak self] event in
                self?.apply(event, to: assistantID)
            }
            try Task.checkCancellation()
            update(assistantID) { $0.text = answer; $0.isPending = false }
        } catch is CancellationError {
            update(assistantID) {
                if $0.text.isEmpty && $0.activity.isEmpty { $0.text = "Stopped." }
                $0.isPending = false
            }
        } catch {
            update(assistantID) {
                $0.text = error.localizedDescription
                $0.isError = true
                $0.isPending = false
            }
        }
    }

    private func apply(_ event: ChatAgentEvent, to id: UUID) {
        switch event {
        case .toolStarted(let call):
            update(id) {
                $0.activity.append(.init(tool: call.name, icon: Self.icon(for: call.name),
                                         text: Self.startLabel(call), done: false))
            }
        case .toolFinished(let name, let summary):
            update(id) {
                if let index = $0.activity.lastIndex(where: { $0.tool == name && !$0.done }) {
                    $0.activity[index].done = true
                    $0.activity[index].text = Self.finishLabel(name, summary: summary)
                }
            }
        }
    }

    private func update(_ id: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&messages[index])
    }

    // MARK: - Activity presentation

    static func icon(for tool: String) -> String {
        switch tool {
        case "search_meetings": return "magnifyingglass"
        case "list_meetings": return "list.bullet"
        case "get_meeting": return "doc.text"
        default: return "wrench.and.screwdriver"
        }
    }

    static func startLabel(_ call: ChatToolCall) -> String {
        switch call.name {
        case "search_meetings": return "Searching meetings for “\(call.string("query") ?? "")”"
        case "list_meetings":
            return call.string("query").map { "Listing meetings matching “\($0)”" } ?? "Listing meetings"
        case "get_meeting": return "Reading meeting \(call.string("id") ?? "latest")"
        default: return "Running \(call.name)"
        }
    }

    static func finishLabel(_ tool: String, summary: String) -> String {
        switch tool {
        case "search_meetings": return "Searched meetings — \(summary)"
        case "list_meetings": return "Listed \(summary)"
        case "get_meeting": return "Read “\(summary)”"
        default: return summary
        }
    }
}
