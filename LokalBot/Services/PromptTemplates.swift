import Foundation

/// System + user prompts for the LLM summariser, parameterised by
/// `NoteTemplate` and `SummaryLanguage`. Ported & slimmed from Seminarly's
/// `PromptTemplates`: LokalBot keeps Markdown output (not JSON), so the
/// per-template prompts return the same section layout we already write to
/// `summary.md`, plus a language directive when the user picked something
/// other than "match transcript".
enum PromptTemplates {

    // MARK: - System prompt

    static func systemPrompt(for template: NoteTemplate,
                             summaryLanguage: SummaryLanguage = .matchTranscript) -> String {
        var lines: [String] = []
        lines.append(persona(for: template))
        lines.append(rules(for: template))
        if let directive = languageSystemDirective(summaryLanguage) {
            lines.append(directive)
        }
        return lines.joined(separator: "\n\n")
    }

    /// Sentence appended to the system prompt when a target language is set.
    /// Returns nil for `.matchTranscript` so existing behaviour is preserved.
    static func languageSystemDirective(_ language: SummaryLanguage) -> String? {
        guard let name = language.promptLanguageName else { return nil }
        return "Write the entire output in \(name). Translate quoted material when needed; keep proper nouns and code identifiers in their original form."
    }

    /// Reinforcement rule used inside the per-template body when a language
    /// is fixed. Returns nil for `.matchTranscript`.
    static func languageRule(_ language: SummaryLanguage) -> String? {
        guard let name = language.promptLanguageName else { return nil }
        return "Output language: \(name). Do not switch back to English."
    }

    // MARK: - User prompt

    /// User-side prompt that wraps a transcript with the template's section
    /// instructions. Pass `language` through so a one-off language switch
    /// reinforces inside the body too.
    static func userPrompt(transcript: String,
                           template: NoteTemplate,
                           summaryLanguage: SummaryLanguage = .matchTranscript) -> String {
        var lines: [String] = []
        lines.append("Transcript follows. \"Me\" is this Mac's user; \"Them\" is the other participants.")
        if let rule = languageRule(summaryLanguage) {
            lines.append(rule)
        }
        lines.append("---")
        lines.append(transcript)
        lines.append("---")
        lines.append("Produce \(template.displayName.lowercased()) notes as Markdown. No preamble, no closing remarks.")
        return lines.joined(separator: "\n\n")
    }

    /// Per-chunk extraction prompt for the map-reduce flow used on long
    /// meetings. The reducer then synthesises a final summary using the
    /// regular `systemPrompt(for:summaryLanguage:)`.
    static func chunkExtractionSystem(summaryLanguage: SummaryLanguage = .matchTranscript) -> String {
        var lines = [
            "Extract the key points, decisions, action items (with [hh:mm:ss] timestamps) and open questions from this part of a meeting transcript as terse Markdown bullets.",
            "\"Me\" is this Mac's user; \"Them\" is the other participants.",
            "No preamble.",
        ]
        if let directive = languageSystemDirective(summaryLanguage) {
            lines.append(directive)
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Per-template prompts

    private static func persona(for template: NoteTemplate) -> String {
        switch template {
        case .meeting:
            return "You are LokalBot, a precise meeting note-taker."
        case .lecture:
            return "You are LokalBot, a careful lecture note-taker who keeps each concept distinct and traceable to the lecturer's wording."
        case .studyGuide:
            return "You are LokalBot, building a study guide that helps the user learn the material, not just remember the lecture."
        case .podcast:
            return "You are LokalBot, summarising a podcast / interview while preserving the speakers' voices and the most repeatable lines."
        case .freeform:
            return "You are LokalBot, a flexible note-taker who groups material by topic without forcing it into a fixed template."
        }
    }

    private static func rules(for template: NoteTemplate) -> String {
        let shared = """
        Be specific; never invent content that is not in the transcript. \
        Quote sparingly and accurately. Respond with Markdown only, no preamble.
        """

        switch template {
        case .meeting:
            return """
            Write a Markdown summary with exactly these sections: \
            ## TL;DR (2-3 sentences), \
            ## Key points (bullets), \
            ## Decisions (bullets, or "None"), \
            ## Action items (markdown checkboxes "- [ ] owner: task", include the [hh:mm:ss] timestamp where each was mentioned, or "None"), \
            ## Open questions (bullets, or "None"). \
            \(shared)
            """
        case .lecture:
            return """
            Write a Markdown summary with exactly these sections: \
            ## TL;DR (2-3 sentences), \
            ## Concepts (bulleted; one concept per bullet, with sub-bullets for sub-points), \
            ## Definitions (term — definition pairs), \
            ## Examples (concise, faithful to the lecturer's wording), \
            ## Questions to review (bullets the student should be able to answer after the lecture). \
            \(shared)
            """
        case .studyGuide:
            return """
            Write a Markdown study guide with exactly these sections: \
            ## TL;DR (2-3 sentences), \
            ## Key concepts (bullets, each with a 1-sentence explanation), \
            ## Flashcards (bullet pairs in the form "Q: … / A: …"), \
            ## Practice questions (open-ended, no answers — designed to test understanding). \
            \(shared)
            """
        case .podcast:
            return """
            Write a Markdown summary with exactly these sections: \
            ## TL;DR (2-3 sentences), \
            ## Topics (bulleted; each topic has a 1-sentence summary), \
            ## Quotes (a few short, accurate quotes attributed to the speaker), \
            ## Insights (bullets — what a listener should take away). \
            \(shared)
            """
        case .freeform:
            return """
            Write Markdown notes grouped by topic. Pick whichever section \
            headings best fit the material — each is a `##` heading with a \
            1-sentence framing, then bullets underneath. Aim for 3-6 sections; \
            do not invent a "Conclusion" section if the transcript doesn't \
            have one. \(shared)
            """
        }
    }
}
