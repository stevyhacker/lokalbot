import Foundation


struct DayDigestGeneratedFocusBlock: Equatable, Sendable {
    var task: String
    var workDone: String
    var status: String
    var outcome: String
    var nextStep: String
    var sourceIDs: [Int64]
}

/// Conservative lexical overlap detection for short, structured digest text.
/// It catches copied or lightly rephrased facts without treating every mention
/// of the same project as redundant.
enum DayDigestTextSimilarity {
    private static let ignoredWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "being", "by",
        "for", "from", "in", "is", "of", "on", "or", "that", "the", "this",
        "to", "was", "were", "with",
    ]

    static func isSimilar(_ lhs: String, _ rhs: String) -> Bool {
        let leftWords = meaningfulWords(in: lhs)
        let rightWords = meaningfulWords(in: rhs)
        guard !leftWords.isEmpty, !rightWords.isEmpty else { return false }

        let leftText = leftWords.joined(separator: " ")
        let rightText = rightWords.joined(separator: " ")
        if leftText == rightText { return true }

        let shorter = leftText.count <= rightText.count ? leftText : rightText
        let longer = leftText.count <= rightText.count ? rightText : leftText
        if shorter.count >= 16, longer.contains(shorter) { return true }

        let left = Set(leftWords)
        let right = Set(rightWords)
        if left == right, left.count >= 2 { return true }

        let sharedCount = left.intersection(right).count
        let smallerCount = min(left.count, right.count)
        guard sharedCount >= 4, smallerCount > 0 else { return false }
        return Double(sharedCount) / Double(smallerCount) >= 0.8
    }

    private static func meaningfulWords(in value: String) -> [String] {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !ignoredWords.contains($0) }
    }
}

enum DayDigestGenerationQuality: String, Codable, Equatable, Sendable {
    case complete
    case partial
    case fallback

    var needsRepair: Bool { self != .complete }
}

struct DayDigestOverviewGeneration: Equatable, Sendable {
    var summary: String
    var quality: DayDigestGenerationQuality
}

/// Converts deterministic, gap-aware evidence segments into the compact
/// human layer shown above the lossless journal. A first model pass rejects
/// metadata-only segments and extracts structured work candidates. A second
/// pass groups those candidates by task; code retains every accepted candidate
/// even if that aggregation pass fails or omits one.
