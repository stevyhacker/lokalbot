import Foundation

/// One continuing commitment assembled from compatible action mentions across
/// meetings. The references remain the source of truth; a thread is only a
/// derived presentation and never replaces or rewrites extracted evidence.
struct ActionThread: Identifiable, Equatable, Sendable {
    let id: String
    let references: [OutcomeActionReference]
    let text: String
    let owner: String?
    let due: String?

    var latestReference: OutcomeActionReference { references[0] }
    var meetingCount: Int { Set(references.map(\.meetingID)).count }
    var mentionCount: Int { references.count }
    var hasMultipleMeetings: Bool { meetingCount > 1 }

    var status: OutcomeStatus {
        references.max {
            if $0.stateUpdatedAt != $1.stateUpdatedAt {
                return $0.stateUpdatedAt < $1.stateUpdatedAt
            }
            if $0.meetingStartedAt != $1.meetingStartedAt {
                return $0.meetingStartedAt < $1.meetingStartedAt
            }
            return $0.id < $1.id
        }?.status ?? .open
    }

    var dueHistory: [String] {
        references.compactMap(\.due).reduce(into: [String]()) { result, due in
            if !result.contains(where: {
                $0.caseInsensitiveCompare(due) == .orderedSame
            }) {
                result.append(due)
            }
        }
    }

    fileprivate init(references: [OutcomeActionReference]) {
        precondition(!references.isEmpty)
        let sorted = references.sorted {
            if $0.meetingStartedAt != $1.meetingStartedAt {
                return $0.meetingStartedAt > $1.meetingStartedAt
            }
            return $0.id < $1.id
        }
        self.references = sorted

        let correctedText = sorted
            .filter(\.textWasCorrected)
            .max { $0.stateUpdatedAt < $1.stateUpdatedAt }
        let descriptiveText = sorted.max {
            if $0.text.count != $1.text.count { return $0.text.count < $1.text.count }
            return $0.meetingStartedAt < $1.meetingStartedAt
        }
        text = (correctedText ?? descriptiveText ?? sorted[0]).text
        owner = sorted
            .filter(\.ownerWasCorrected)
            .max { $0.stateUpdatedAt < $1.stateUpdatedAt }?.owner
            ?? sorted.compactMap(\.owner).first
        due = sorted
            .filter(\.dueWasCorrected)
            .max { $0.stateUpdatedAt < $1.stateUpdatedAt }?.due
            ?? sorted.compactMap { reference in
                reference.due.map { (reference.meetingStartedAt, $0) }
            }.max { $0.0 < $1.0 }?.1
        id = Self.stableID(for: sorted)
    }

    private static func stableID(for references: [OutcomeActionReference]) -> String {
        let value = references.map(\.id).sorted().joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "thread-%016llx", hash)
    }
}

/// Conservative lexical grouping for commitments. It deliberately
/// avoids a model call: uncertain pairs stay separate, while every grouped
/// reference remains available for inspection and navigation.
enum ActionThreadClusterer {
    static let maximumMeetingSpan: TimeInterval = 30 * 86_400

    static func cluster(_ references: [OutcomeActionReference]) -> [ActionThread] {
        let sorted = references.sorted {
            if $0.meetingStartedAt != $1.meetingStartedAt {
                return $0.meetingStartedAt > $1.meetingStartedAt
            }
            return $0.id < $1.id
        }
        var groups: [[OutcomeActionReference]] = []

        for reference in sorted {
            if let index = groups.firstIndex(where: { group in
                guard let representative = group.first,
                      !group.contains(where: { $0.meetingID == reference.meetingID })
                else { return false }
                return likelySameCommitment(reference, representative)
            }) {
                groups[index].append(reference)
            } else {
                groups.append([reference])
            }
        }

        return groups.map(ActionThread.init).sorted {
            if $0.latestReference.meetingStartedAt != $1.latestReference.meetingStartedAt {
                return $0.latestReference.meetingStartedAt > $1.latestReference.meetingStartedAt
            }
            return $0.id < $1.id
        }
    }

    private static func likelySameCommitment(
        _ lhs: OutcomeActionReference,
        _ rhs: OutcomeActionReference
    ) -> Bool {
        guard abs(lhs.meetingStartedAt.timeIntervalSince(rhs.meetingStartedAt))
                <= maximumMeetingSpan,
              compatibleOwners(lhs, rhs)
        else { return false }

        let leftTokens = OutcomeTextSimilarity.significantTokens(lhs.text)
        let rightTokens = OutcomeTextSimilarity.significantTokens(rhs.text)
        // Short generic commitments recur naturally and are unsafe to merge.
        guard leftTokens.count >= 3, rightTokens.count >= 3 else { return false }

        let leftIdentifiers = OutcomeTextSimilarity.identifierTokens(lhs.text)
        let rightIdentifiers = OutcomeTextSimilarity.identifierTokens(rhs.text)
        if !leftIdentifiers.isEmpty,
           !rightIdentifiers.isEmpty,
           leftIdentifiers.isDisjoint(with: rightIdentifiers) {
            return false
        }

        if OutcomeTextSimilarity.normalized(lhs.text)
            == OutcomeTextSimilarity.normalized(rhs.text) {
            return true
        }
        let intersection = leftTokens.intersection(rightTokens).count
        let union = leftTokens.union(rightTokens).count
        guard union > 0 else { return false }
        let jaccard = Double(intersection) / Double(union)
        let containment = Double(intersection) / Double(min(leftTokens.count, rightTokens.count))
        return jaccard >= 0.72 && containment >= 0.80
    }

    private static func compatibleOwners(
        _ lhs: OutcomeActionReference,
        _ rhs: OutcomeActionReference
    ) -> Bool {
        if lhs.isForUser || rhs.isForUser { return lhs.isForUser && rhs.isForUser }
        guard let left = lhs.owner.map(OutcomeTextSimilarity.normalized),
              let right = rhs.owner.map(OutcomeTextSimilarity.normalized),
              !left.isEmpty,
              !right.isEmpty
        else { return false }
        return left == right
    }
}

enum OutcomeTextSimilarity {
    private static let leadingNoise: Set<String> = [
        "a", "an", "i", "ill", "me", "my", "need", "please", "the", "to", "we", "will",
    ]

    static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(normalized(text).split(separator: " ").map(String.init))
    }

    static func significantTokens(_ text: String) -> Set<String> {
        tokens(text).subtracting(leadingNoise)
    }

    static func identifierTokens(_ text: String) -> Set<String> {
        Set(tokens(text).filter { token in token.contains(where: \.isNumber) })
    }

    static func isSimilar(_ lhs: String, _ rhs: String, threshold: Double) -> Bool {
        let left = tokens(lhs)
        let right = tokens(rhs)
        let union = left.union(right)
        guard !union.isEmpty else { return false }
        return Double(left.intersection(right).count) / Double(union.count) >= threshold
    }
}
