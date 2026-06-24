import Combine
import Foundation
import CryptoKit

/// One line in the chat transcript. `activity` holds the tool steps the
/// assistant ran for this turn (shown as chips above its answer). Codable so
/// conversations persist; `isPending` is transient and never written.
struct ChatMessage: Identifiable, Equatable, Codable {
    struct Activity: Identifiable, Equatable, Codable {
        let id: UUID
        let tool: String
        let icon: String
        var text: String
        var done: Bool

        init(id: UUID = UUID(), tool: String, icon: String, text: String, done: Bool) {
            self.id = id; self.tool = tool; self.icon = icon; self.text = text; self.done = done
        }
    }

    let id: UUID
    let role: ChatRole
    var text: String
    var activity: [Activity]
    /// The assistant turn is still being generated. Transient — never persisted.
    var isPending: Bool
    /// The turn failed (engine unreachable, no model, …) — rendered as an error.
    var isError: Bool

    init(id: UUID = UUID(), role: ChatRole, text: String,
         activity: [Activity] = [], isPending: Bool = false, isError: Bool = false) {
        self.id = id; self.role = role; self.text = text
        self.activity = activity; self.isPending = isPending; self.isError = isError
    }

    private enum CodingKeys: String, CodingKey { case id, role, text, activity, isError }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decode(ChatRole.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        activity = try c.decodeIfPresent([Activity].self, forKey: .activity) ?? []
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        isPending = false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        if !activity.isEmpty { try c.encode(activity, forKey: .activity) }
        if isError { try c.encode(isError, forKey: .isError) }
    }
}

/// A saved chat conversation — the unit of history persisted to disk.
struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]

    init(id: UUID = UUID(), title: String = ChatViewModel.newChatTitle,
         createdAt: Date = Date(), updatedAt: Date = Date(), messages: [ChatMessage] = []) {
        self.id = id; self.title = title; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.messages = messages
    }
}

/// Persists chat conversations as one JSON file per conversation under
/// `<root>/chats/`, mirroring the file-per-document layout used for meetings
/// and journals. Personal scale: the whole set loads into memory and each
/// save rewrites a single small file atomically.
@MainActor
final class ChatStore {
    private let dir: URL

    init(rootURL: URL) {
        dir = rootURL.appendingPathComponent("chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let keyAccount = "chat-key"

    private func fileURL(_ id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).json.enc")
    }

    func loadAll() -> [Conversation] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        let key = try? KeychainSecrets.symmetricKey(account: Self.keyAccount)
        var result: [Conversation] = []
        for file in files {
            switch file.pathExtension {
            case "enc":
                guard let key,
                      let data = try? Data(contentsOf: file),
                      let box = try? AES.GCM.SealedBox(combined: data),
                      let plain = try? AES.GCM.open(box, using: key),
                      let convo = try? Self.decoder.decode(Conversation.self, from: plain)
                else { continue }
                result.append(convo)
            case "json":
                // Legacy plaintext (pre-encryption): load it, then migrate to a
                // sealed file — deleting the plaintext only once the encrypted
                // copy is safely written.
                guard let data = try? Data(contentsOf: file),
                      let convo = try? Self.decoder.decode(Conversation.self, from: data)
                else { continue }
                result.append(convo)
                if save(convo) { try? FileManager.default.removeItem(at: file) }
            default:
                continue
            }
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Encode → AES-GCM seal (per-install Keychain key) → atomic write. Returns
    /// whether the sealed file landed, so the migration above never discards
    /// plaintext before its encrypted replacement exists.
    @discardableResult
    func save(_ conversation: Conversation) -> Bool {
        guard let key = try? KeychainSecrets.symmetricKey(account: Self.keyAccount),
              let data = try? Self.encoder.encode(conversation),
              let combined = try? AES.GCM.seal(data, using: key).combined else { return false }
        do {
            try combined.write(to: fileURL(conversation.id), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(id))
        // Drop any legacy plaintext that was never migrated.
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent("\(id.uuidString).json"))
    }
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
    /// All saved conversations, most-recently-updated first (drives the list).
    @Published private(set) var conversations: [Conversation] = []
    /// The conversation currently shown in the transcript.
    @Published private(set) var currentID: UUID

    nonisolated static let newChatTitle = "New chat"

    /// Prompt chips shown on the empty state.
    let suggestions = [
        "What did we decide in my last meeting?",
        "List my recent meetings",
        "Search my meetings for action items",
    ]

    private let makeEngine: () async throws -> TextEngine
    private let tools: ChatToolRunner
    private let store: ChatStore
    private var task: Task<Void, Never>?

    init(makeEngine: @escaping () async throws -> TextEngine, tools: ChatToolRunner, store: ChatStore) {
        self.makeEngine = makeEngine
        self.tools = tools
        self.store = store
        let saved = store.loadAll()
        if let latest = saved.first {
            conversations = saved
            currentID = latest.id
            messages = latest.messages
        } else {
            let fresh = Conversation()
            conversations = [fresh]
            currentID = fresh.id
        }
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
        persist()

        task = Task { [weak self] in
            await self?.run(latest: text, history: history, assistantID: assistantID)
        }
    }

    /// Cancel an in-flight response.
    func stop() { task?.cancel() }

    /// Start a new, empty conversation (persisting the current one first).
    func newConversation() {
        stop()
        persist()
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
        persist()
        currentID = id
        messages = conversations.first { $0.id == id }?.messages ?? []
    }

    /// Delete a conversation from disk and the list.
    func delete(_ id: UUID) {
        stop()
        store.delete(id)
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
    private func persist() {
        guard let index = conversations.firstIndex(where: { $0.id == currentID }) else { return }
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
        if !clean.isEmpty { store.save(convo) }
    }

    /// A one-line conversation title derived from the first user message.
    private static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 48 ? String(trimmed.prefix(48)) + "…" : trimmed
    }

    // MARK: - Run

    private func run(latest: String, history: [ChatAgent.Turn], assistantID: UUID) async {
        defer { isResponding = false; persist() }
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
