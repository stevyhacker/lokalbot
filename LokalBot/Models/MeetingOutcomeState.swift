import Foundation

enum OutcomeStatus: String, Codable, CaseIterable, Sendable {
    case open
    case done
    case deferred

    var label: String { rawValue.capitalized }
}

/// User-owned workflow state layered over immutable extracted outcomes.
struct MeetingOutcomeState: Codable, Equatable, Sendable {
    static let fileName = "outcome-state.json"
    static let currentSchemaVersion = 1

    struct ActionState: Codable, Equatable, Sendable {
        var status: OutcomeStatus
        var ownerOverride: String?
        var dueOverride: String?
        var textCorrection: String?
        var updatedAt: Date
        var userEdited: Bool

        init(status: OutcomeStatus = .open, ownerOverride: String? = nil,
             dueOverride: String? = nil, textCorrection: String? = nil,
             updatedAt: Date = Date(), userEdited: Bool = false) {
            self.status = status
            self.ownerOverride = ownerOverride
            self.dueOverride = dueOverride
            self.textCorrection = textCorrection
            self.updatedAt = updatedAt.outcomePersistedTimestamp
            self.userEdited = userEdited
        }

        private enum CodingKeys: String, CodingKey {
            case status, ownerOverride, dueOverride, textCorrection, updatedAt, userEdited
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decodeIfPresent(OutcomeStatus.self, forKey: .status) ?? .open
            ownerOverride = try container.decodeIfPresent(String.self, forKey: .ownerOverride)
            dueOverride = try container.decodeIfPresent(String.self, forKey: .dueOverride)
            textCorrection = try container.decodeIfPresent(String.self, forKey: .textCorrection)
            updatedAt = (try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date())
                .outcomePersistedTimestamp
            userEdited = try container.decodeIfPresent(Bool.self, forKey: .userEdited)
                ?? (status != .open || ownerOverride != nil || dueOverride != nil
                    || textCorrection != nil)
        }
    }

    var schemaVersion = currentSchemaVersion
    var actions: [String: ActionState] = [:]

    func state(for action: MeetingOutcomes.ActionItem) -> ActionState {
        actions[action.id] ?? ActionState()
    }
}

/// Editable follow-up content. No sending integration is attached to this
/// model: the approved workflow is review, copy, or export only.
struct FollowUpDraft: Codable, Equatable, Sendable {
    static let fileName = "follow-up-draft.json"
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var recipient = ""
    var cc = ""
    var subject = ""
    var body = ""
    var updatedAt = Date()
    var seeded = true
    var reviewed = false
    var sourceMeetingID: UUID?

    static func seeded(for meeting: Meeting, outcomes: MeetingOutcomes) -> FollowUpDraft {
        let decisions = outcomes.decisionRecords.prefix(3).map { "- \($0.text)" }
        let actions = outcomes.actionItems.prefix(5).map { item in
            let owner = item.owner.map { " -- \($0)" } ?? ""
            let due = item.due.map { " (\($0))" } ?? ""
            return "- \(item.text)\(owner)\(due)"
        }
        var sections = ["Hi,", "", "Here is the follow-up from \(meeting.displayTitle)."]
        if !decisions.isEmpty {
            sections += ["", "Decisions", decisions.joined(separator: "\n")]
        }
        if !actions.isEmpty {
            sections += ["", "Next steps", actions.joined(separator: "\n")]
        }
        sections += ["", "Best,"]
        return FollowUpDraft(
            subject: "Follow-up: \(meeting.displayTitle)",
            body: sections.joined(separator: "\n"),
            seeded: true,
            reviewed: false,
            sourceMeetingID: meeting.id)
    }

    init(schemaVersion: Int = currentSchemaVersion, recipient: String = "",
         cc: String = "", subject: String = "", body: String = "",
         updatedAt: Date = Date(), seeded: Bool = true, reviewed: Bool = false,
         sourceMeetingID: UUID? = nil) {
        self.schemaVersion = schemaVersion
        self.recipient = recipient
        self.cc = cc
        self.subject = subject
        self.body = body
        self.updatedAt = updatedAt.outcomePersistedTimestamp
        self.seeded = seeded
        self.reviewed = reviewed
        self.sourceMeetingID = sourceMeetingID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, recipient, cc, subject, body, updatedAt
        case seeded, reviewed, sourceMeetingID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        recipient = try container.decodeIfPresent(String.self, forKey: .recipient) ?? ""
        cc = try container.decodeIfPresent(String.self, forKey: .cc) ?? ""
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        updatedAt = (try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date())
            .outcomePersistedTimestamp
        seeded = try container.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
        reviewed = try container.decodeIfPresent(Bool.self, forKey: .reviewed) ?? false
        sourceMeetingID = try container.decodeIfPresent(UUID.self, forKey: .sourceMeetingID)
    }
}

extension Date {
    /// ISO-8601 persistence uses millisecond precision. Normalize mutation
    /// timestamps at creation so in-memory and reloaded workflow state agree.
    var outcomePersistedTimestamp: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }
}
