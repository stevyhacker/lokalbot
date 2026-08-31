import Foundation

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
            self.id = id
            self.tool = tool
            self.icon = icon
            self.text = text
            self.done = done
        }
    }

    let id: UUID
    let role: ChatRole
    var text: String
    var activity: [Activity]
    /// Sources enabled for this specific question. Empty on legacy turns.
    var sourceScopes: [AskSourceScope]
    /// The assistant turn is still being generated. Transient — never persisted.
    var isPending: Bool
    /// The turn failed (engine unreachable, no model, …) — rendered as an error.
    var isError: Bool

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        activity: [Activity] = [],
        sourceScopes: [AskSourceScope] = [],
        isPending: Bool = false,
        isError: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.activity = activity
        self.sourceScopes = sourceScopes
        self.isPending = isPending
        self.isError = isError
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, activity, sourceScopes, isError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(ChatRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        activity = try container.decodeIfPresent([Activity].self, forKey: .activity) ?? []
        sourceScopes = try container.decodeIfPresent(
            [AskSourceScope].self,
            forKey: .sourceScopes
        ) ?? []
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        isPending = false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        if !activity.isEmpty {
            try container.encode(activity, forKey: .activity)
        }
        if !sourceScopes.isEmpty {
            try container.encode(sourceScopes, forKey: .sourceScopes)
        }
        if isError {
            try container.encode(isError, forKey: .isError)
        }
    }
}

/// A saved chat conversation — the unit of history persisted to disk.
struct Conversation: Identifiable, Codable, Equatable {
    static let untitledTitle = "New chat"

    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]

    init(
        id: UUID = UUID(),
        title: String = Conversation.untitledTitle,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}
