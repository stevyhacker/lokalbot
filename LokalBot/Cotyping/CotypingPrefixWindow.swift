import Foundation

/// Pure rules for "should we generate, and on how much context." Ported from
/// Cotabby's `SuggestionRequestFactory.shouldGenerateSuggestion` +
/// `truncatedPromptPrefix`.
enum CotypingPrefixWindow {
    /// Generate only when there is at least one non-whitespace character before
    /// the caret (no suggestions on a blank field).
    static func shouldGenerate(for precedingText: String) -> Bool {
        !precedingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Keep only the latest short tail so long stale context cannot steer the
    /// model: last `maxCharacters`, then the last `maxWords` of those.
    static func truncatedPrefix(
        from precedingText: String, maxCharacters: Int, maxWords: Int
    ) -> String {
        let characterWindow = String(precedingText.suffix(maxCharacters))
        let trailingWords = characterWindow
            .split(whereSeparator: { $0.isWhitespace })
            .suffix(maxWords)
            .map(String.init)
            .joined(separator: " ")
        // Preserve the trailing whitespace/newlines of the character window when
        // the word rejoin would otherwise drop a meaningful boundary the caret
        // sits on (e.g. a trailing space the user just typed).
        if trailingWords.isEmpty { return characterWindow }
        if let last = characterWindow.last, last.isWhitespace {
            return trailingWords + String(last)
        }
        return trailingWords
    }
}
