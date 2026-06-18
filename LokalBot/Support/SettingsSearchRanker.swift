import Foundation

/// Pure matcher backing the Settings search field. A section is shown when every
/// whitespace-separated token of the query appears somewhere in the section's
/// searchable text (title + keywords). Empty query matches everything.
///
/// Kept tiny and `nonisolated` so it is unit-testable off the main actor and the
/// view layer stays free of search logic.
enum SettingsSearchRanker {
    static func matches(query: String, haystack: [String]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return true }
        let hay = haystack.joined(separator: " ").lowercased()
        return trimmed.split(whereSeparator: { $0.isWhitespace }).allSatisfy { hay.contains($0) }
    }
}
