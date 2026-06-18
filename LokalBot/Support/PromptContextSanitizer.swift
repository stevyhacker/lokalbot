import Foundation

/// Normalises free-form text before it is spliced into an LLM prompt.
///
/// Transcript and context text arrives with stray control bytes, ragged spacing,
/// and stacked blank lines that waste the model's context budget without adding
/// meaning. This keeps the real content — letters, digits, punctuation, normal
/// spacing — and only tidies the noise, so the policy stays pure, shared, and
/// easy to test. Unlike a terminal/clipboard sanitiser it does NOT strip
/// punctuation: a meeting transcript needs its commas and question marks.
enum PromptContextSanitizer {
    private static let space: Unicode.Scalar = " "
    private static let newline: Unicode.Scalar = "\n"
    private static let newlineScalars = CharacterSet.newlines
    private static let controlScalars = CharacterSet.controlCharacters
    private static let inlineWhitespace = CharacterSet.whitespaces
    /// Ellipsis is a single Swift `Character`, so it costs one unit against `maxCharacters`.
    private static let ellipsis: Character = "\u{2026}"

    /// Returns prompt-ready text: control characters removed, runs of whitespace
    /// and blank lines collapsed, edges trimmed, and — when `maxCharacters` is
    /// given — hard-capped to that length with a trailing ellipsis at the last
    /// word boundary (the ellipsis is counted within the cap).
    static func sanitize(_ text: String, maxCharacters: Int? = nil) -> String {
        // Single scalar pass: fold every newline variant (U+2028/2029, CRLF, …)
        // to "\n", and turn control/format scalars into spaces. Replacing rather
        // than deleting keeps a boundary so "raw\u{0007}output" reads as two
        // words, not one. Everything else passes through untouched.
        var folded = String.UnicodeScalarView()
        folded.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if newlineScalars.contains(scalar) {
                folded.append(newline)
            } else if controlScalars.contains(scalar) {
                folded.append(space)
            } else {
                folded.append(scalar)
            }
        }

        let cleanedLines = String(folded)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { collapseInlineWhitespace(String($0)) }

        // Collapse a run of blank lines down to a single separator and drop
        // leading/trailing blanks, so paragraph breaks survive but dead space
        // does not.
        var lines: [String] = []
        var pendingBlank = false
        for line in cleanedLines {
            if line.isEmpty {
                pendingBlank = !lines.isEmpty
            } else {
                if pendingBlank { lines.append("") }
                pendingBlank = false
                lines.append(line)
            }
        }

        let trimmed = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let cap = maxCharacters else { return trimmed }
        guard cap > 0 else { return "" }
        guard trimmed.count > cap else { return trimmed }
        return hardCap(trimmed, to: cap)
    }

    /// Collapses every run of inline whitespace (spaces, tabs-turned-spaces,
    /// non-breaking spaces) to one ASCII space and trims the line's edges.
    /// Newlines are already split out, so they never appear here.
    private static func collapseInlineWhitespace(_ line: String) -> String {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(line.unicodeScalars.count)
        var pendingSpace = false
        for scalar in line.unicodeScalars {
            if inlineWhitespace.contains(scalar) {
                pendingSpace = true
            } else {
                if pendingSpace, !result.isEmpty { result.append(space) }
                pendingSpace = false
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// Truncates `text` to at most `cap` characters, ending on a word boundary
    /// with an ellipsis. Falls back to a hard cut when a single token is longer
    /// than the budget. Caller guarantees `cap > 0` and `text.count > cap`.
    private static func hardCap(_ text: String, to cap: Int) -> String {
        let budget = cap - 1   // reserve one character for the ellipsis
        guard budget > 0 else { return String(text.prefix(cap)) }

        let head = text.prefix(budget)
        if let breakIndex = head.lastIndex(where: { $0.isWhitespace }) {
            let word = head[..<breakIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty { return word + String(ellipsis) }
        }
        return String(head) + String(ellipsis)
    }
}
