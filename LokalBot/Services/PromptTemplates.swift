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
                             summaryLanguage: SummaryLanguage = .matchTranscript,
                             userSpeakerLabel: String = "Me") -> String {
        var lines: [String] = []
        lines.append(persona(for: template))
        lines.append(rules(for: template))
        lines.append(userActionabilityRule(userSpeakerLabel: userSpeakerLabel))
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
                           summaryLanguage: SummaryLanguage = .matchTranscript,
                           userSpeakerLabel: String = "Me") -> String {
        var lines: [String] = []
        lines.append("Transcript follows. The speaker labeled \"\(normalizedSpeakerLabel(userSpeakerLabel))\" is this Mac's user (\"Me\"); every other speaker is another participant.")
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
    static func chunkExtractionSystem(summaryLanguage: SummaryLanguage = .matchTranscript,
                                      userSpeakerLabel: String = "Me") -> String {
        let user = normalizedSpeakerLabel(userSpeakerLabel)
        var lines = [
            "Extract the key points, decisions, action items (with [hh:mm:ss] timestamps) and open questions from this part of a meeting transcript as terse Markdown bullets.",
            "The speaker labeled \"\(user)\" is this Mac's user (\"Me\"); every other speaker is another participant.",
            "Perform a separate actionability pass: under ## Action items, use ### Me for commitments made by \"\(user)\", requests or assignments directed to \"\(user)\", and agreed follow-ups \"\(user)\" owns; use ### Others for everyone else's tasks. Write \"None\" under either subgroup when this part contains no qualifying item.",
            "Do not turn generic advice, optional ideas, or another participant's work into an action for Me.",
            "No preamble.",
        ]
        if let directive = languageSystemDirective(summaryLanguage) {
            lines.append(directive)
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Other production prompts
    //
    // Every prompt the app ships lives here (the chat agent's system prompt is
    // the one exception — it is co-located with its tool-call parser in
    // `ChatAgent`). Views and engines reference these instead of owning copy.

    /// Day digest (Capture's day overview + `--digest`): workday summary from
    /// the activity log, meeting list, and OCR'd screen text.
    static let dayDigestSystem =
        "You summarize a person's workday from their app/window activity log, meeting list, and OCR'd on-screen text. Write Markdown: ## What I worked on (grouped bullets, by project/topic inferred from window titles AND the on-screen text), ## Meetings (or 'None'), ## Time allocation (one-line table of top apps). Lean on the screen text for concrete detail; be specific, never invent."

    /// Chat-backend autocomplete fallback (cotyping via Ollama / Apple
    /// Intelligence; the built-in llama-server uses the raw endpoint instead).
    static let autocompleteSystem =
        "You are an autocomplete engine. Continue the user's text naturally from exactly where it stops. Output ONLY the continuation — no quotes, no preamble, no explanation, no restating prior text. Keep it to a short phrase."

    /// Models-view "test generation" connectivity check.
    static let connectivityTestSystem = "You are a connectivity test. Reply with one short sentence."
    static let connectivityTestPrompt = "Say hello and name the model you are."

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
            ## Action items (use the required `### Me` / `### Others` format below), \
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
            ## Questions to review (bullets the student should be able to answer after the lecture), \
            ## Action items (use the required `### Me` / `### Others` format below). \
            \(shared)
            """
        case .studyGuide:
            return """
            Write a Markdown study guide with exactly these sections: \
            ## TL;DR (2-3 sentences), \
            ## Key concepts (bullets, each with a 1-sentence explanation), \
            ## Flashcards (bullet pairs in the form "Q: … / A: …"), \
            ## Practice questions (open-ended, no answers — designed to test understanding), \
            ## Action items (use the required `### Me` / `### Others` format below). \
            \(shared)
            """
        case .podcast:
            return """
            Write a Markdown summary with exactly these sections: \
            ## TL;DR (2-3 sentences), \
            ## Topics (bulleted; each topic has a 1-sentence summary), \
            ## Quotes (a few short, accurate quotes attributed to the speaker), \
            ## Insights (bullets — what a listener should take away), \
            ## Action items (use the required `### Me` / `### Others` format below). \
            \(shared)
            """
        case .freeform:
            return """
            Write Markdown notes grouped by topic. Pick whichever section \
            headings best fit the material — each is a `##` heading with a \
            1-sentence framing, then bullets underneath. Aim for 3-6 topical sections, \
            then finish with ## Action items using the required `### Me` / `### Others` format below; \
            do not invent a "Conclusion" section if the transcript doesn't \
            have one. \(shared)
            """
        }
    }

    /// Mandatory across every notes template. Separating the user's work from
    /// everyone else's prevents a generic action-items list from hiding the
    /// one part of a recap the user most often needs immediately after a call.
    private static func userActionabilityRule(userSpeakerLabel: String) -> String {
        let user = normalizedSpeakerLabel(userSpeakerLabel)
        return """
        Before finalizing, always perform a separate actionability pass for this Mac's user. \
        The transcript speaker labeled "\(user)" is the user; call that owner "Me" in the notes. \
        In `## Action items`, always include both of these subheadings:
        ### Me
        Include explicit commitments made by "\(user)", requests or assignments directed to \
        "\(user)", and agreed follow-ups "\(user)" owns. Use Markdown checkboxes in the form \
        `- [ ] task — [hh:mm:ss]`; preserve any stated deadline. Write `None` when no supported \
        action for Me exists.
        ### Others
        Include other participants' concrete tasks as `- [ ] owner: task — [hh:mm:ss]`, or \
        `None`. Never turn generic advice, optional ideas, unresolved possibilities, or work owned \
        only by someone else into an action for Me. Check the transcript and user-written note \
        context, but never invent an action.
        """
    }

    private static func normalizedSpeakerLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Me" : trimmed
    }
}
