import Foundation

/// Pure matcher backing the Settings search field. A section is shown when every
/// whitespace-separated token of the query appears somewhere in the section's
/// searchable text (title + keywords). Empty query matches everything.
///
/// Kept tiny and `nonisolated` so it is unit-testable off the main actor and the
/// view layer stays free of search logic.
enum SettingsSearchRanker {
    static func matches(query: String, haystack: [String]) -> Bool {
        let queryTokens = tokens(in: query)
        guard !queryTokens.isEmpty else { return true }
        let hay = normalized(haystack.joined(separator: " "))
        return queryTokens.allSatisfy { hay.contains($0) }
    }

    private static func tokens(in text: String) -> [String] {
        normalized(text)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    private static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return String(folded.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        })
    }
}
