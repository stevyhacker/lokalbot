import Foundation

/// Builds the completion prompt for cotyping. Ported from Cotabby's
/// `BaseCompletionPromptRenderer`: the model is treated as a pure *text
/// continuer*, not an instruction-follower. Persona / style / language are
/// folded into a short conditioning preface (a model conditions on a
/// description, it does not obey a command in this mode), and the caret prefix
/// is the LAST thing in the prompt, trailing-trimmed so generation begins at a
/// clean word boundary.
///
/// LokalBot's recommended cotyping model is instruction-tuned rather than a base model, but
/// raw `/v1/completions` still continues text from this prompt. The renderer
/// therefore returns the exact conditioning preface separately as well, so the
/// output boundary can suppress a partial or complete preface echo.
enum CotypingPromptRenderer {
    struct RenderedPrompt: Equatable, Sendable {
        let prompt: String
        let conditioningPreface: String?
    }

    /// Upper bound on the conditioning preface so a long style note can never
    /// crowd the prompt; the caret prefix arrives pre-windowed by
    /// `CotypingPrefixWindow`.
    static let maxPrefaceCharacters = 900
    /// Cap on the single clipboard line (distinct from the upstream clip budget).
    static let maxClipboardLineCharacters = 180
    /// Cap on each accepted-completion memory line.
    static let maxLearnedExampleCharacters = 120

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
        languageHint: String? = nil,
        extendedContext: String? = nil,
        clipboardContext: String? = nil,
        learnedExamples: [String] = []
    ) -> String {
        render(
            prefixText: prefixText,
            surfaceLines: surfaceLines,
            userName: userName,
            styleNote: styleNote,
            languageHint: languageHint,
            extendedContext: extendedContext,
            clipboardContext: clipboardContext,
            learnedExamples: learnedExamples).prompt
    }

    /// Returns both the wire prompt and the exact (post-truncation) hidden
    /// preface. Keeping that boundary explicit lets output filtering compare
    /// against what the model really saw instead of duplicating prompt labels.
    static func render(
        prefixText: String,
        surfaceLines: [String] = [],
        userName: String? = nil,
        styleNote: String? = nil,
        languageHint: String? = nil,
        extendedContext: String? = nil,
        clipboardContext: String? = nil,
        learnedExamples: [String] = []
    ) -> RenderedPrompt {
        let prefix = trimmingTrailingWhitespace(prefixText)

        var preface: [String] = surfaceLines
        if let persona = personaLine(userName) { preface.append(persona) }
        if let style = styleLine(styleNote) { preface.append(style) }
        if let language = nonEmpty(languageHint) { preface.append(language) }
        if let notes = nonEmpty(extendedContext) {
            preface.append("Notes the writer keeps in mind: \(String(notes.prefix(300)))")
        }
        for example in learnedExamples {
            if let example = nonEmpty(example) {
                preface.append("Previously accepted completion: \(String(example.prefix(maxLearnedExampleCharacters)))")
            }
        }
        if let clip = nonEmpty(clipboardContext) {
            preface.append("On the clipboard: \(String(clip.prefix(maxClipboardLineCharacters)))")
        }

        guard !preface.isEmpty else {
            // No context to condition on: hand the model the bare text.
            return RenderedPrompt(prompt: prefix, conditioningPreface: nil)
        }

        var prefaceText = preface.joined(separator: "\n")
        if prefaceText.count > maxPrefaceCharacters {
            prefaceText = String(prefaceText.prefix(maxPrefaceCharacters))
        }
        // Blank line separates the conditioning preface from the live text
        // without a label the model could echo. Prefix stays the final bytes.
        return RenderedPrompt(
            prompt: prefaceText + "\n\n" + prefix,
            conditioningPreface: prefaceText)
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
