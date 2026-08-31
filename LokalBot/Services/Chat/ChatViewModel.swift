import Combine
import Foundation

/// Drives the Chat section: owns the message list and runs `ChatAgent` against
/// the same `TextEngine` the summariser uses (resolved lazily per send via
/// `ThinkExecution.makeTextEngine`, so it always reflects the current
/// Settings → Models choice and boots the built-in server on first use).
@MainActor
final class ChatViewModel: ObservableObject {
    enum ResponsePhase: Equatable {
        case preparingEngine
        case startingAssistant
    }

    @Published private(set) var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published private(set) var isResponding = false
    @Published private(set) var responsePhase: ResponsePhase?
    /// All saved conversations, most-recently-updated first (drives the list).
    @Published private(set) var conversations: [Conversation] = []
    /// The conversation currently shown in the transcript.
    @Published private(set) var currentID = UUID()
    @Published private(set) var persistenceError: String?

    nonisolated static let newChatTitle = Conversation.untitledTitle

    /// Prompt chips shown on the empty state.
    let suggestions = [
        "What did we decide in my last meeting?",
        "List my recent meetings",
        "Search my meetings for action items",
    ]

    private let makeEngine: () async throws -> TextEngine
    private let tools: ChatToolRunner
    private let store: ChatStore
    /// Re-read per send so an overnight dream lands in the next question
    /// without restarting the app. Empty when dreaming is off or has nothing.
    private let workMemory: () -> String
    private var task: Task<Void, Never>?
    private struct RetryPayload {
        var prompt: String
        var displayText: String
        var scopes: Set<AskSourceScope>
    }
    private var retryPayloads: [UUID: RetryPayload] = [:]

    init(makeEngine: @escaping () async throws -> TextEngine, tools: ChatToolRunner,
         store: ChatStore, workMemory: @escaping () -> String = { "" }) {
        self.makeEngine = makeEngine
        self.tools = tools
        self.store = store
        self.workMemory = workMemory
        do {
            let load = try store.loadAll()
            if let latest = load.conversations.first {
                conversations = load.conversations
                currentID = latest.id
                messages = latest.messages
            } else {
                let fresh = Conversation()
                conversations = [fresh]
                currentID = fresh.id
            }
            if !load.issues.isEmpty {
                persistenceError = "Loaded chat history, but \(load.issues.count) conversation file"
                    + (load.issues.count == 1 ? "" : "s") + " could not be read or migrated."
                load.issues.prefix(10).forEach { lokalbotLog("chat storage issue: \($0.message)") }
            }
        } catch {
            let fresh = Conversation()
            conversations = [fresh]
            currentID = fresh.id
            persistenceError = "Chat history could not be loaded: \(error.localizedDescription)"
        }
    }

    /// Send the current draft (or an explicit `prompt`, e.g. a suggestion chip).
    /// `displayText` keeps model-only context such as attached OCR excerpts out
    /// of the visible transcript while still sending it in the current turn.
    func send(_ prompt: String? = nil, displayText: String? = nil,
              sourceScopes: Set<AskSourceScope> = AskSourceScope.defaults) {
        let text = (prompt ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        let trimmedDisplay = displayText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleText = trimmedDisplay.flatMap { $0.isEmpty ? nil : $0 } ?? text
        draft = ""

        // History = finalised turns only (skip the pending/error placeholders).
        let history = messages
            .filter { !$0.isPending && !$0.isError }
            .map { ChatAgent.Turn(role: $0.role, text: $0.text) }

        let orderedScopes = AskSourceScope.allCases.filter(sourceScopes.contains)
        messages.append(ChatMessage(
            role: .user, text: visibleText, sourceScopes: orderedScopes))
        let assistant = ChatMessage(
            role: .assistant, text: "", sourceScopes: orderedScopes, isPending: true)
        let assistantID = assistant.id
        messages.append(assistant)
        isResponding = true
        responsePhase = .preparingEngine
        retryPayloads[assistantID] = .init(
            prompt: text, displayText: visibleText, scopes: sourceScopes)
        persist()

        task = Task { [weak self] in
            await self?.run(
                latest: text,
                history: history,
                assistantID: assistantID,
                scopes: sourceScopes)
        }
    }

    /// Cancel an in-flight response.
    func stop() { task?.cancel() }

    func canRetry(_ assistantID: UUID) -> Bool {
        guard !isResponding,
              let index = messages.firstIndex(where: { $0.id == assistantID }),
              messages[index].role == .assistant,
              messages[index].isError else { return false }
        return retryPayloads[assistantID] != nil
            || messages[..<index].last(where: { $0.role == .user }) != nil
    }

    /// Retry an errored assistant turn without duplicating the visible user
    /// message. In-session retries preserve hidden screen/day context; a
    /// persisted error safely falls back to the preceding visible question.
    func retry(_ assistantID: UUID) {
        guard canRetry(assistantID),
              let assistantIndex = messages.firstIndex(where: { $0.id == assistantID }),
              let userIndex = messages[..<assistantIndex].lastIndex(where: { $0.role == .user })
        else { return }
        let payload = retryPayloads[assistantID]
            ?? .init(
                prompt: messages[userIndex].text,
                displayText: messages[userIndex].text,
                scopes: Set(messages[userIndex].sourceScopes.isEmpty
                    ? AskSourceScope.allCases : messages[userIndex].sourceScopes))
        messages.remove(at: assistantIndex)
        messages.remove(at: userIndex)
        retryPayloads[assistantID] = nil
        send(payload.prompt, displayText: payload.displayText, sourceScopes: payload.scopes)
    }

    /// Start a new, empty conversation (persisting the current one first).
    func newConversation() {
        stop()
        guard persist() else { return }
        // Already on an empty conversation? Stay put rather than pile up blanks.
        if messages.isEmpty { return }
        let fresh = Conversation()
        conversations.insert(fresh, at: 0)
        currentID = fresh.id
        messages = []
    }

    /// Switch the transcript to a previously-saved conversation.
    func select(_ id: UUID) {
        guard id != currentID else { return }
        stop()
        guard persist() else { return }
        currentID = id
        messages = conversations.first { $0.id == id }?.messages ?? []
    }

    /// Delete a conversation from disk and the list.
    func delete(_ id: UUID) {
        stop()
        do {
            try store.delete(id)
            persistenceError = nil
        } catch {
            persistenceError = "The conversation was not deleted: \(error.localizedDescription)"
            return
        }
        conversations.removeAll { $0.id == id }
        guard id == currentID else { return }
        if let next = conversations.first {
            currentID = next.id
            messages = next.messages
        } else {
            let fresh = Conversation()
            conversations = [fresh]
            currentID = fresh.id
            messages = []
        }
    }

    /// Fold the live transcript back into its conversation and persist it.
    /// In-flight / empty assistant placeholders are dropped so a half-finished
    /// turn never lands on disk.
    @discardableResult
    private func persist() -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == currentID }) else { return true }
        let clean = messages
            .filter { !($0.role == .assistant && $0.text.isEmpty && !$0.isError) }
            .map { message -> ChatMessage in
                var copy = message
                copy.isPending = false
                return copy
            }
        var convo = conversations[index]
        convo.messages = clean
        convo.updatedAt = Date()
        if convo.title == Self.newChatTitle, let firstUser = clean.first(where: { $0.role == .user }) {
            convo.title = Self.title(from: firstUser.text)
        }
        conversations.remove(at: index)
        conversations.insert(convo, at: 0)
        guard !clean.isEmpty else { return true }
        do {
            try store.save(convo)
            persistenceError = nil
            return true
        } catch {
            persistenceError = "The current conversation was not saved: \(error.localizedDescription)"
            return false
        }
    }

    func dismissPersistenceError() {
        persistenceError = nil
    }

    /// A one-line conversation title derived from the first user message.
    private static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 48 ? String(trimmed.prefix(48)) + "…" : trimmed
    }

    // MARK: - Run

    private func run(latest: String, history: [ChatAgent.Turn], assistantID: UUID,
                     scopes: Set<AskSourceScope>) async {
        defer {
            isResponding = false
            responsePhase = nil
            persist()
        }
        do {
            let engine = try await makeEngine()
            responsePhase = .startingAssistant
            let scopedTools = ScopedChatToolRunner(base: tools, scopes: scopes)
            var agent = ChatAgent(engine: engine, runner: scopedTools)
            agent.workMemory = workMemory()
            let answer = try await agent.respond(history: history, latest: latest) { [weak self] event in
                self?.apply(event, to: assistantID)
            }
            try Task.checkCancellation()
            update(assistantID) { $0.text = answer; $0.isPending = false }
            retryPayloads[assistantID] = nil
        } catch is CancellationError {
            update(assistantID) {
                if $0.text.isEmpty && $0.activity.isEmpty { $0.text = "Stopped." }
                $0.isPending = false
            }
            retryPayloads[assistantID] = nil
        } catch {
            lokalbotLog("chat response failed: \(error.localizedDescription)")
            update(assistantID) {
                $0.text = Self.friendlyFailureMessage(for: error)
                $0.isError = true
                $0.isPending = false
            }
        }
    }

    nonisolated static func friendlyFailureMessage(for error: Error) -> String {
        if error is ModelDownloadManager.PreparationError {
            return "The assistant model could not be downloaded. Check your connection and free disk space, then try again."
        }
        if error is LlamaServer.ServerError {
            return "The on-device assistant could not start. Close memory-heavy apps or choose a smaller model, then try again."
        }
        if let engineError = error as? TextEngineError {
            switch engineError {
            case .noModel:
                return "No Main LLM is selected. Choose one in Settings → Models, then try again."
            case .serverUnreachable:
                return "The selected assistant could not be reached. Check its settings, then try again."
            case .httpStatus(let code, _, _):
                if code == 401 || code == 403 {
                    return "The selected assistant rejected its API key. Check the key in Settings, then try again."
                }
                if code == 429 {
                    return "The selected assistant is rate-limited. Wait briefly, then try again."
                }
                return "The assistant could not complete that request. Check the selected model in Settings, then try again."
            case .badResponse, .outputTruncated, .unavailable:
                return "The assistant could not complete that request. Check the selected model in Settings, then try again."
            }
        }
        return "The assistant could not complete that request. Check the selected model in Settings, then try again."
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
        case "get_action_items": return "checklist"
        case "search_screen": return "camera.viewfinder"
        case "activity_summary": return "chart.bar.doc.horizontal"
        default: return "wrench.and.screwdriver"
        }
    }

    static func startLabel(_ call: ChatToolCall) -> String {
        switch call.name {
        case "search_meetings": return "Searching meetings for “\(call.string("query") ?? "")”"
        case "list_meetings":
            return call.string("query").map { "Listing meetings matching “\($0)”" } ?? "Listing meetings"
        case "get_meeting": return "Reading meeting \(call.string("id") ?? "latest")"
        case "get_action_items":
            return call.string("id").map { "Collecting outcomes from meeting \($0)" }
                ?? "Collecting recent outcomes"
        case "search_screen": return "Searching screen text for “\(call.string("query") ?? "")”"
        case "activity_summary": return "Summarising activity for \(call.string("day") ?? "today")"
        default: return "Running \(call.name)"
        }
    }

    static func finishLabel(_ tool: String, summary: String) -> String {
        switch tool {
        case "search_meetings": return "Searched meetings — \(summary)"
        case "list_meetings": return "Listed \(summary)"
        case "get_meeting": return "Read “\(summary)”"
        case "get_action_items": return "Collected outcomes — \(summary)"
        case "search_screen": return "Searched screen text — \(summary)"
        case "activity_summary": return "Summarised \(summary)"
        default: return summary
        }
    }
}
