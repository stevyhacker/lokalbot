import Foundation

/// Formats a word count for display, e.g. `1` -> "1 word", `1234` -> "1,234 words".
///
/// Grouping is done by hand rather than via `NumberFormatter` so the output is
/// locale-independent and deterministic for tests — a formatter would render
/// "1.234" or "1 234" depending on the user's region.
enum WordCountFormatter {
    /// "<grouped count> word(s)". Negative input is treated as `0`; the unit is
    /// singular only for exactly one word.
    static func format(words: Int) -> String {
        let count = max(0, words)
        let unit = count == 1 ? "word" : "words"
        return "\(grouped(count)) \(unit)"
    }

    /// Inserts a comma every three digits from the right ("1234" -> "1,234").
    /// `count` is assumed non-negative, so there is no sign to preserve.
    private static func grouped(_ count: Int) -> String {
        let digits = String(count)
        guard digits.count > 3 else { return digits }

        var result = ""
        result.reserveCapacity(digits.count + digits.count / 3)
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return String(result.reversed())
    }
}
