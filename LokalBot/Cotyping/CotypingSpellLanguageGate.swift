import Foundation
import NaturalLanguage

/// Decides whether native spell-check verdicts apply to the text at the caret.
/// macOS ships dictionaries for a fixed language set; text in any other
/// language (Serbian, Croatian, Montenegrin, …) is flagged word-by-word as
/// "misspelled" by whichever dictionary is active, and every spell-gated
/// policy — the typo gate, the seam guard, the word-prefix validity signal —
/// would silently suppress cotyping for the entire language. When the caret
/// context is confidently in a language with no installed dictionary, spell
/// verdicts stand down and the continuation pipeline runs ungated.
nonisolated enum CotypingSpellLanguageGate {
    /// Caret-preceding window used for identification: large enough for the
    /// recognizer to be reliable, small enough to stay cheap per keystroke.
    static let contextWindowCharacters = 200
    /// Below this the recognizer is guessing (a lone short fragment), so spell
    /// checking stays on — identical behavior to before this gate existed.
    static let minimumConfidence = 0.5
    /// Language-recognizer confidence varies between macOS releases for a
    /// single token, which is never enough evidence to disable spell checks.
    static let minimumWordCount = 2

    static func spellVerdictsApply(context: String, availableLanguages: [String]) -> Bool {
        let window = String(context.suffix(contextWindowCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !window.isEmpty else { return true }
        guard window.split(whereSeparator: { $0.isWhitespace }).count >= minimumWordCount else {
            return true
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(window)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= minimumConfidence else {
            return true
        }
        return hasDictionary(for: language.rawValue, in: availableLanguages)
    }

    /// Dictionary coverage by base language code: "en" covers "en_GB", "pt"
    /// covers "pt_BR". Serbian/Croatian/Bosnian match nothing on a stock system.
    static func hasDictionary(for languageCode: String, in availableLanguages: [String]) -> Bool {
        let base = baseCode(languageCode)
        guard !base.isEmpty else { return true }
        return availableLanguages.contains { baseCode($0) == base }
    }

    private static func baseCode(_ identifier: String) -> String {
        identifier.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .first.map { $0.lowercased() } ?? ""
    }
}
