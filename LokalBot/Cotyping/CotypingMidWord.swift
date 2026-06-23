import Foundation

/// Mid-word continuation rules. Ports Cotabby's `MidWordContinuationPolicy`.
///
/// When the caret sits strictly inside a word (a word character on BOTH sides),
/// the suggestion must continue that word, not start a new one. Cotabby enforces
/// this in-process by masking the first sampled token so it carries no leading
/// whitespace. LokalBot talks to an HTTP `llama-server`, so it can't mask a
/// token mid-generation; instead `CotypingTextNormalizer` reproduces the same
/// outcome at the output layer using these pure helpers: never re-type the
/// current partial word, and (strictly inside) never begin with whitespace.
enum CotypingMidWord {
    /// True only when the caret is strictly inside a word — a letter/digit
    /// immediately before AND after it. At a word end (nothing or punctuation
    /// after the caret) this is false, so ordinary next-word prediction (which
    /// wants a leading space) is left untouched — exactly Cotabby's policy.
    static func shouldForceContinuation(precedingText: String, trailingText: String) -> Bool {
        guard let before = precedingText.last, isWordCharacter(before) else { return false }
        guard let after = trailingText.first, isWordCharacter(after) else { return false }
        return true
    }

    /// The run of word characters the caret currently sits at the end of (the
    /// partial word being typed), or "" when the caret is not mid-word.
    static func currentPartialWord(in precedingText: String) -> String {
        var reversed: [Character] = []
        for character in precedingText.reversed() {
            guard isWordCharacter(character) else { break }
            reversed.append(character)
        }
        return String(reversed.reversed())
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
