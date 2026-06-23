import Foundation

/// Builds the completion prompt for cotyping. Ported from Cotabby's
/// `BaseCompletionPromptRenderer`: the model is treated as a pure *text
/// continuer*, not an instruction-follower. Persona / style / language are
/// folded into a short conditioning preface (a model conditions on a
/// description, it does not obey a command in this mode), and the caret prefix
/// is the LAST thing in the prompt, trailing-trimmed so generation begins at a
/// clean word boundary.
///
/// LokalBot's built-in model is instruction-tuned rather than a base model, but
/// raw `/v1/completions` still continues text from this prompt; the conditioning
/// preface + `CotypingTextNormalizer` keep the output usable.
enum CotypingPromptRenderer {
    /// Upper bound on the conditioning preface so a long style note can never
    /// crowd the prompt; the caret prefix arrives pre-windowed by
    /// `CotypingPrefixWindow`.
    static let maxPrefaceCharacters = 600

    /// - Parameters:
    ///   - prefixText: the windowed text immediately before the caret.
    ///   - userName: optional author name → "Written by <name>." (voice cue).
    ///   - styleNote: optional free-form style guidance → "Writing style: …".
    ///   - languageHint: optional language preface (already phrased).
    static func prompt(
        prefixText: String,
        surfaceLines: [String] = [],
        userName: String? = nil,
        styleNote: String? = nil,
        languageHint: String? = nil
    ) -> String {
        let prefix = trimmingTrailingWhitespace(prefixText)

        var preface: [String] = surfaceLines
        if let persona = personaLine(userName) { preface.append(persona) }
        if let style = styleLine(styleNote) { preface.append(style) }
        if let language = nonEmpty(languageHint) { preface.append(language) }

        guard !preface.isEmpty else {
            // No context to condition on: hand the model the bare text.
            return prefix
        }

        var prefaceText = preface.joined(separator: "\n")
        if prefaceText.count > maxPrefaceCharacters {
            prefaceText = String(prefaceText.prefix(maxPrefaceCharacters))
        }
        // Blank line separates the conditioning preface from the live text
        // without a label the model could echo. Prefix stays the final bytes.
        return prefaceText + "\n\n" + prefix
    }

    /// "Written by <name>." or nil — conditions the voice via authorship framing.
    private static func personaLine(_ userName: String?) -> String? {
        guard let name = nonEmpty(userName) else { return nil }
        return "Written by \(name)."
    }

    /// "Writing style: <note>." or nil.
    private static func styleLine(_ note: String?) -> String? {
        guard let note = nonEmpty(note) else { return nil }
        return "Writing style: \(note)."
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Drops trailing spaces, tabs, and newlines so the prompt ends at a word
    /// boundary (matters for a base-style continuation).
    static func trimmingTrailingWhitespace(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let prev = text.index(before: end)
            if text[prev].isWhitespace { end = prev } else { break }
        }
        return String(text[text.startIndex..<end])
    }
}
