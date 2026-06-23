import AppKit
import Foundation

/// NSSpellChecker-backed typo detection + correction for cotyping autocorrect.
/// Ports Cotabby's `CurrentWordSpellChecker`: native, instant, offline,
/// multilingual, and the same engine the system underlines with. Flags
/// non-words only — real-word errors (their/there) are out of scope. A unique
/// spell-document tag isolates our session from other text-checking state.
@MainActor
final class CotypingSpellChecker {
    private let documentTag = NSSpellChecker.uniqueSpellDocumentTag()

    /// True when the whole word is misspelled (range must start at 0 and span the
    /// entire word, so partly-flagged tokens like `I'm` don't misfire).
    func isTypo(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        let range = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: nil, wrap: false,
            inSpellDocumentWithTag: documentTag, wordCount: nil)
        return range.location == 0 && range.length == (word as NSString).length
    }

    /// The single best fix: the top native guess that's a different single word,
    /// recased to match the typo. `nil` when there's no usable guess.
    func bestCorrection(for word: String) -> String? {
        let range = NSRange(location: 0, length: (word as NSString).length)
        let guesses = NSSpellChecker.shared.guesses(
            forWordRange: range, in: word, language: nil, inSpellDocumentWithTag: documentTag) ?? []
        let candidate = guesses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0.lowercased() != word.lowercased() && !$0.contains(" ") }
        guard let candidate else { return nil }
        return CotypingCaseTransfer.applying(caseOf: word, to: candidate)
    }
}
