import Foundation

enum MeetingOutcomeStore {
    static func loadState(from folder: URL) -> MeetingOutcomeState {
        decode(MeetingOutcomeState.self, at: folder.appendingPathComponent(MeetingOutcomeState.fileName))
            ?? MeetingOutcomeState()
    }

    static func writeState(_ state: MeetingOutcomeState, to folder: URL) throws {
        try write(state, to: folder.appendingPathComponent(MeetingOutcomeState.fileName))
    }

    static func loadFollowUp(from folder: URL) -> FollowUpDraft? {
        decode(FollowUpDraft.self, at: folder.appendingPathComponent(FollowUpDraft.fileName))
    }

    static func writeFollowUp(_ draft: FollowUpDraft, to folder: URL) throws {
        try write(draft, to: folder.appendingPathComponent(FollowUpDraft.fileName))
    }

    /// Carry user-owned workflow state across a safe re-extraction. Exact IDs
    /// win; otherwise a record must retain either the same source segment or a
    /// near-identical normalized commitment before its overlay is transferred.
    static func reconcileState(
        _ state: MeetingOutcomeState,
        from previous: MeetingOutcomes,
        to next: MeetingOutcomes
    ) -> MeetingOutcomeState {
        var reconciled = MeetingOutcomeState()
        var consumed: Set<String> = []

        for action in next.actionItems {
            if let exact = state.actions[action.id] {
                reconciled.actions[action.id] = exact
                consumed.insert(action.id)
                continue
            }

            let candidate = previous.actionItems
                .filter { state.actions[$0.id] != nil && !consumed.contains($0.id) }
                .map { old in (old: old, score: matchScore(old, action)) }
                .filter { $0.score >= 0.8 }
                .max { $0.score < $1.score }
            if let candidate, let priorState = state.actions[candidate.old.id] {
                reconciled.actions[action.id] = priorState
                consumed.insert(candidate.old.id)
            }
        }
        return reconciled
    }

    private static func decode<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = fractionalISO8601.date(from: value)
                ?? legacyISO8601.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date: \(value)")
        }
        return try? decoder.decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalISO8601.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// Preserve sub-second edits while continuing to read the second-precision
    /// ISO-8601 dates written by LokalBot before the outcome-state overlay.
    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let legacyISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func matchScore(_ lhs: MeetingOutcomes.ActionItem,
                                   _ rhs: MeetingOutcomes.ActionItem) -> Double {
        let leftCitations = Set(lhs.citations.map(\.segmentID))
        let rightCitations = Set(rhs.citations.map(\.segmentID))
        let sharesEvidence = !leftCitations.isDisjoint(with: rightCitations)
        let leftTokens = tokens(lhs.text)
        let rightTokens = tokens(rhs.text)
        let union = leftTokens.union(rightTokens)
        let textScore = union.isEmpty ? 0
            : Double(leftTokens.intersection(rightTokens).count) / Double(union.count)
        if normalized(lhs.text) == normalized(rhs.text) { return 1 }
        return sharesEvidence ? max(0.85, textScore) : textScore
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(normalized(text).split(separator: " ").map(String.init))
    }
}
