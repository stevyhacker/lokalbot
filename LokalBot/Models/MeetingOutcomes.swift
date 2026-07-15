import Foundation

/// Structured outcomes extracted from a meeting after summarization: action
/// items, decisions, and open questions as data rather than prose. Persisted
/// as `outcomes.json` next to `summary.md` — files stay the source of truth;
/// the chat tool and the meeting detail view both read this shape.
struct MeetingOutcomes: Codable, Equatable {
    struct ActionItem: Codable, Equatable {
        var text: String
        /// Who it's on, exactly as named in the meeting ("Me", "Ana"). Nil
        /// when no owner was stated — never guessed.
        var owner: String?
        /// Due date/time as spoken ("Friday", "by end of Q3"), not normalized.
        var due: String?

        init(text: String, owner: String? = nil, due: String? = nil) {
            self.text = text
            self.owner = owner
            self.due = due
        }

        var isForUser: Bool {
            guard let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return owner.caseInsensitiveCompare("Me") == .orderedSame
        }
    }

    var actionItems: [ActionItem] = []
    var decisions: [String] = []
    var openQuestions: [String] = []

    var isEmpty: Bool { actionItems.isEmpty && decisions.isEmpty && openQuestions.isEmpty }
    var userActionItems: [ActionItem] { actionItems.filter(\.isForUser) }
    var otherActionItems: [ActionItem] { actionItems.filter { !$0.isForUser } }

    static let fileName = "outcomes.json"

    static func load(from folder: URL) -> MeetingOutcomes? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else {
            return nil
        }
        return try? JSONDecoder().decode(MeetingOutcomes.self, from: data)
    }

    func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(
            to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
