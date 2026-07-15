import Foundation

/// Prompt, JSON schema, and tolerant parsing for the outcomes extraction pass
/// that runs after summarization. Pure so every piece is unit-testable
/// without an engine; the pipeline owns the actual generate call.
///
/// The schema goes through `TextEngine.generate(system:prompt:context:schema:)`
/// — llama-server compiles it to a grammar so the reply is valid by
/// construction, while unconstrained backends (Apple Intelligence) fall back
/// to the prompt's format instructions plus the tolerant parse here.
enum OutcomesExtractor {

    static let transcriptCharacterLimit = 24_000

    static func systemPrompt(userSpeakerLabel: String = "Me") -> String {
        let user = normalizedSpeakerLabel(userSpeakerLabel)
        return """
        You extract structured outcomes from meeting notes. Reply with ONLY a JSON \
        object of this exact shape:
        {"action_items": [{"text": "...", "owner": "...", "due": "...", "for_user": true}], \
        "decisions": ["..."], "open_questions": ["..."]}

        Rules:
        - The transcript speaker labeled "\(user)" is this Mac's user. Before returning, \
        explicitly check for everything actionable for that user: commitments made by \
        "\(user)", requests or assignments directed to "\(user)", and agreed follow-ups \
        "\(user)" owns.
        - action_items: concrete tasks a participant committed to, was assigned, or was \
        directly asked to do. "due" is the deadline as spoken. Use "" when no due date \
        was stated — never guess.
        - Set "for_user" to true exactly when the action belongs to the user. For those \
        items, set "owner" to "Me" even when the transcript uses "\(user)". Otherwise, \
        use the owner's name exactly as it appears, or "" when no owner was stated.
        - Put all "for_user": true items first. Do not classify generic advice, optional \
        ideas, unresolved possibilities, or another participant's work as user action items.
        - decisions: choices the participants settled on.
        - open_questions: questions raised but left unresolved.
        - Keep every entry to one short sentence, in the language of the notes.
        - Use empty arrays when nothing qualifies. Never invent items.
        """
    }

    /// JSON schema matching `systemPrompt`'s shape, for grammar-constrained
    /// backends. `owner`/`due` are required-but-emptyable rather than optional,
    /// and `for_user` is required so strict grammars keep the object shape fixed.
    static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action_items": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "owner": ["type": "string"],
                            "due": ["type": "string"],
                            "for_user": ["type": "boolean"],
                        ],
                        "required": ["text", "owner", "due", "for_user"],
                    ],
                ],
                "decisions": ["type": "array", "items": ["type": "string"]],
                "open_questions": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["action_items", "decisions", "open_questions"],
        ]
    }

    /// What to feed the extraction: the transcript when it fits a single
    /// prompt (same 24k threshold as `ProcessingPipeline.summarize`), else the
    /// already-condensed summary body.
    static func prompt(transcriptMarkdown: String, summary: String) -> String {
        let source = transcriptMarkdown.count > transcriptCharacterLimit ? summary : transcriptMarkdown
        return "Extract the outcomes from these meeting notes:\n\n" + source
    }

    /// Tolerant parse of the model's reply. Accepts fenced/prefixed JSON via
    /// the same balanced-brace scan the chat agent uses; empty-string owner/due
    /// collapse to nil. Nil when no parseable object is found.
    static func parse(_ output: String, userSpeakerLabel: String = "Me") -> MeetingOutcomes? {
        guard let json = ChatPrompt.extractJSONObject(strippingReasoning(output)),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var outcomes = MeetingOutcomes()
        for raw in object["action_items"] as? [Any] ?? [] {
            guard let item = raw as? [String: Any],
                  let text = cleaned(item["text"]) else { continue }
            let rawOwner = cleaned(item["owner"])
            let belongsToUser = item["for_user"] as? Bool == true
                || isUserOwner(rawOwner, userSpeakerLabel: userSpeakerLabel)
            outcomes.actionItems.append(.init(text: text,
                                              owner: belongsToUser ? "Me" : rawOwner,
                                              due: cleaned(item["due"])))
        }
        outcomes.actionItems = outcomes.userActionItems + outcomes.otherActionItems
        outcomes.decisions = strings(object["decisions"])
        outcomes.openQuestions = strings(object["open_questions"])
        return outcomes
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { cleaned($0) }
    }

    private static func cleaned(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private static func isUserOwner(_ owner: String?, userSpeakerLabel: String) -> Bool {
        guard let owner else { return false }
        return owner.caseInsensitiveCompare("Me") == .orderedSame
            || owner.caseInsensitiveCompare(normalizedSpeakerLabel(userSpeakerLabel)) == .orderedSame
    }

    private static func normalizedSpeakerLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Me" : trimmed
    }
}
