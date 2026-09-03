import Foundation

/// A transcript-backed source reference stored with an extracted outcome.
/// The transcript stays immutable; this record is only a durable pointer into
/// it, plus a short excerpt so older outcomes remain understandable if a
/// transcript is later repaired.
struct OutcomeSourceCitation: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Redundant with the per-meeting folder for new records, but persisted so
    /// exported/indexed citations remain self-identifying outside that folder.
    var meetingID: UUID?
    var segmentID: String
    var start: TimeInterval
    var end: TimeInterval
    var speaker: String
    var excerpt: String

    var id: String { segmentID }

    init(meetingID: UUID? = nil, segmentID: String, start: TimeInterval,
         end: TimeInterval, speaker: String, excerpt: String) {
        self.meetingID = meetingID
        self.segmentID = segmentID
        self.start = start
        self.end = end
        self.speaker = speaker
        self.excerpt = excerpt
    }
}

/// Structured outcomes extracted from a meeting after summarization. The
/// extracted text and evidence are immutable source data; user corrections and
/// workflow status live separately in `MeetingOutcomeState`.
struct MeetingOutcomes: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3
    static let maximumActionItems = 10
    static let maximumOtherActionItems = 5

    struct ActionItem: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var schemaVersion: Int
        var text: String
        /// Who it is on, exactly as named in the meeting ("Me", "Ana"). Nil
        /// when no owner was stated -- never guessed.
        var owner: String?
        /// Due date/time as spoken ("Friday", "by end of Q3"), not normalized.
        var due: String?
        /// Stored extraction judgment. Legacy records derive it from owner.
        var isForUser: Bool
        /// Relative meeting importance assigned by the grounded extraction
        /// pass. This is used only to select the most useful actions owned by
        /// other participants; every user-owned action is retained.
        var importance: Int
        var citations: [OutcomeSourceCitation]

        static let defaultImportance = 3
        static let minimumImportance = 1
        static let maximumImportance = 5

        init(id: String? = nil, text: String, owner: String? = nil,
             due: String? = nil, isForUser: Bool? = nil,
             importance: Int = defaultImportance,
             citations: [OutcomeSourceCitation] = [],
             schemaVersion: Int = MeetingOutcomes.currentSchemaVersion) {
            let resolvedIsForUser = isForUser ?? Self.ownerBelongsToUser(owner)
            let proseText = OutcomeProse.actionText(text, isForUser: resolvedIsForUser)
            self.id = id ?? MeetingOutcomes.stableID(
                kind: "action", text: proseText, owner: owner, due: due,
                citationIDs: citations.map(\.segmentID))
            self.schemaVersion = schemaVersion
            self.text = proseText
            self.owner = owner
            self.due = due
            self.isForUser = resolvedIsForUser
            self.importance = Self.clampedImportance(importance)
            self.citations = citations
        }

        var displayText: String {
            OutcomeProse.actionText(text, isForUser: isForUser)
        }

        private static func ownerBelongsToUser(_ owner: String?) -> Bool {
            guard let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return owner.caseInsensitiveCompare("Me") == .orderedSame
        }

        private static func clampedImportance(_ importance: Int) -> Int {
            min(maximumImportance, max(minimumImportance, importance))
        }

        private enum CodingKeys: String, CodingKey {
            case id, schemaVersion, text, owner, due, isForUser, importance, citations
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(
                Int.self, forKey: .schemaVersion) ?? 1
            let decodedText = try container.decode(String.self, forKey: .text)
            owner = try container.decodeIfPresent(String.self, forKey: .owner)
            due = try container.decodeIfPresent(String.self, forKey: .due)
            citations = try container.decodeIfPresent(
                [OutcomeSourceCitation].self, forKey: .citations) ?? []
            let storedIsForUser = try container.decodeIfPresent(
                Bool.self, forKey: .isForUser)
            isForUser = storedIsForUser == true
                || Self.ownerBelongsToUser(owner)
                || OutcomeProse.hasFirstPersonSubject(decodedText)
            if isForUser { owner = "Me" }
            importance = Self.clampedImportance(
                try container.decodeIfPresent(Int.self, forKey: .importance)
                    ?? Self.defaultImportance)
            text = OutcomeProse.actionText(decodedText, isForUser: isForUser)
            id = try container.decodeIfPresent(String.self, forKey: .id)
                ?? MeetingOutcomes.stableID(
                    kind: "action", text: text, owner: owner, due: due,
                    citationIDs: citations.map(\.segmentID))
            schemaVersion = MeetingOutcomes.currentSchemaVersion
        }
    }

    struct Decision: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var schemaVersion: Int
        var text: String
        var citations: [OutcomeSourceCitation]

        init(id: String? = nil, text: String,
             citations: [OutcomeSourceCitation] = [],
             schemaVersion: Int = MeetingOutcomes.currentSchemaVersion) {
            let proseText = OutcomeProse.firstPersonSubject(text)
            self.id = id ?? MeetingOutcomes.stableID(
                kind: "decision", text: proseText,
                citationIDs: citations.map(\.segmentID))
            self.schemaVersion = schemaVersion
            self.text = proseText
            self.citations = citations
        }

        var displayText: String { OutcomeProse.firstPersonSubject(text) }

        private enum CodingKeys: String, CodingKey {
            case id, schemaVersion, text, citations
        }

        init(from decoder: Decoder) throws {
            // A decision was a plain string in schema v1. Decode both shapes.
            if let single = try? decoder.singleValueContainer(),
               let text = try? single.decode(String.self) {
                self.init(text: text)
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedText = try container.decode(String.self, forKey: .text)
            let decodedCitations = try container.decodeIfPresent(
                [OutcomeSourceCitation].self, forKey: .citations) ?? []
            self.init(
                id: try container.decodeIfPresent(String.self, forKey: .id),
                text: decodedText,
                citations: decodedCitations,
                schemaVersion: try container.decodeIfPresent(
                    Int.self, forKey: .schemaVersion) ?? 1)
        }
    }

    var schemaVersion: Int = currentSchemaVersion
    var actionItems: [ActionItem] = []
    var decisionRecords: [Decision] = []
    var openQuestions: [String] = []

    /// Compatibility surface used by routines and chat formatting. New UI
    /// reads `decisionRecords` so it can render evidence citations.
    var decisions: [String] {
        get { decisionRecords.map(\.text) }
        set { decisionRecords = newValue.map { Decision(text: $0) } }
    }

    init(actionItems: [ActionItem] = [], decisions: [String] = [],
         openQuestions: [String] = []) {
        self.actionItems = actionItems
        decisionRecords = decisions.map { Decision(text: $0) }
        self.openQuestions = openQuestions
    }

    var isEmpty: Bool {
        actionItems.isEmpty && decisionRecords.isEmpty && openQuestions.isEmpty
    }
    var userActionItems: [ActionItem] { actionItems.filter(\.isForUser) }
    var otherActionItems: [ActionItem] { actionItems.filter { !$0.isForUser } }

    /// Keeps all of the user's work first, then fills the remaining room with
    /// at most five of everyone else's highest-importance actions. If the user
    /// alone owns more than ten actions, preserving their complete list wins
    /// over the normal ten-item readability ceiling.
    func prioritizingActionItems() -> Self {
        var prioritized = self
        let userItems = userActionItems
        let remainingSlots = max(0, Self.maximumActionItems - userItems.count)
        let otherLimit = min(Self.maximumOtherActionItems, remainingSlots)
        let otherItems = otherActionItems
            .sorted(by: Self.higherPriorityAction)
            .prefix(otherLimit)
        prioritized.actionItems = userItems + otherItems
        return prioritized
    }

    static let fileName = "outcomes.json"

    static func load(from folder: URL) -> MeetingOutcomes? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else {
            return nil
        }
        return try? JSONDecoder().decode(MeetingOutcomes.self, from: data)
            .prioritizingActionItems()
    }

    func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(
            to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, actionItems, decisionRecords, openQuestions
        case legacyActionItems = "action_items"
        case legacyDecisions = "decisions"
        case legacyOpenQuestions = "open_questions"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        actionItems = try container.decodeIfPresent(
            [ActionItem].self, forKey: .actionItems)
            ?? container.decodeIfPresent([ActionItem].self, forKey: .legacyActionItems)
            ?? []
        decisionRecords = try container.decodeIfPresent(
            [Decision].self, forKey: .decisionRecords)
            ?? container.decodeIfPresent([Decision].self, forKey: .legacyDecisions)
            ?? []
        openQuestions = try container.decodeIfPresent(
            [String].self, forKey: .openQuestions)
            ?? container.decodeIfPresent([String].self, forKey: .legacyOpenQuestions)
            ?? []
        schemaVersion = Self.currentSchemaVersion
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(actionItems, forKey: .actionItems)
        try container.encode(decisionRecords, forKey: .decisionRecords)
        try container.encode(openQuestions, forKey: .openQuestions)
    }

    private static func higherPriorityAction(_ lhs: ActionItem, _ rhs: ActionItem) -> Bool {
        if lhs.importance != rhs.importance { return lhs.importance > rhs.importance }
        let left = lhs.citations.first?.start ?? .infinity
        let right = rhs.citations.first?.start ?? .infinity
        if left != right { return left < right }
        return lhs.text.localizedCaseInsensitiveCompare(rhs.text) == .orderedAscending
    }

    /// FNV-1a keeps identity stable across app launches and re-extractions.
    /// Swift's `Hasher` is intentionally randomized and cannot be persisted.
    static func stableID(kind: String, text: String, owner: String? = nil,
                         due: String? = nil, citationIDs: [String] = []) -> String {
        let normalized = ([kind, text, owner ?? "", due ?? ""] + citationIDs)
            .map {
                $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
            .joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
