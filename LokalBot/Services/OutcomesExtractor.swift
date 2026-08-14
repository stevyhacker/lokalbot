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
        {"action_items": [{"text": "...", "owner": "...", "due": "...", "for_user": true, \
        "source_segment_ids": ["segment-..."]}], "decisions": [{"text": "...", \
        "source_segment_ids": ["segment-..."]}], "open_questions": ["..."]}

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
        - Every action item and decision must cite one or more source_segment_ids \
        copied exactly from the notes. Never invent or alter a segment ID.
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
                            "source_segment_ids": [
                                "type": "array", "items": ["type": "string"],
                            ],
                        ],
                        "required": ["text", "owner", "due", "for_user", "source_segment_ids"],
                        "additionalProperties": false,
                    ],
                ],
                "decisions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "source_segment_ids": [
                                "type": "array", "items": ["type": "string"],
                            ],
                        ],
                        "required": ["text", "source_segment_ids"],
                        "additionalProperties": false,
                    ],
                ],
                "open_questions": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["action_items", "decisions", "open_questions"],
            "additionalProperties": false,
        ]
    }

    /// What to feed the extraction: the transcript when it fits a single
    /// prompt (same 24k threshold as `ProcessingPipeline.summarize`), else the
    /// already-condensed summary body.
    static func prompt(transcriptMarkdown: String, summary: String) -> String {
        let source = transcriptMarkdown.count > transcriptCharacterLimit ? summary : transcriptMarkdown
        return "Extract the outcomes from these meeting notes:\n\n" + source
    }

    /// Grounded extraction input with stable segment IDs. Long meetings keep
    /// the generated summary for coverage and add only complete transcript
    /// segments up to the prompt budget, so an ID is never truncated.
    static func prompt(transcript: Transcript, summary: String) -> String {
        let evidence = transcript.evidenceMarkdown
        if evidence.count <= transcriptCharacterLimit {
            return "Extract the outcomes from these source-labelled meeting notes:\n\n" + evidence
        }

        let summaryBlock = summary.isEmpty ? "" : "Meeting summary:\n\(summary)\n\n"
        let budget = max(4_000, transcriptCharacterLimit - summaryBlock.count)
        var selected: [String] = []
        var used = 0
        for index in transcript.segments.indices {
            let segment = transcript.segments[index]
            let line = "[\(transcript.segmentID(at: index))] "
                + "[\(Transcript.stamp(segment.start))] "
                + "\(transcript.displaySpeaker(for: segment.speaker)): \(segment.displayText)"
            guard used + line.count + 2 <= budget else { break }
            selected.append(line)
            used += line.count + 2
        }
        return "Extract the outcomes from the summary and source-labelled evidence. "
            + "Only cite IDs that appear below.\n\n"
            + summaryBlock + selected.joined(separator: "\n\n")
    }

    /// Tolerant parse of the model's reply. Accepts fenced/prefixed JSON via
    /// the same balanced-brace scan the chat agent uses; empty-string owner/due
    /// collapse to nil. Nil when no parseable object is found.
    static func parse(_ output: String, userSpeakerLabel: String = "Me") -> MeetingOutcomes? {
        parse(output, userSpeakerLabel: userSpeakerLabel, sourceSegments: nil,
              meetingID: nil, requireEvidence: false)
    }

    /// Evidence-validating parse used by the processing pipeline. Unknown or
    /// missing source IDs are never promoted into trusted action/decision rows.
    static func parse(_ output: String, userSpeakerLabel: String = "Me",
                      sourceSegments: [String: Transcript.Segment]?,
                      meetingID: Meeting.ID? = nil,
                      requireEvidence: Bool) -> MeetingOutcomes? {
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
            let citations = resolveCitations(
                item["source_segment_ids"], sourceSegments: sourceSegments,
                meetingID: meetingID)
            guard !requireEvidence || !citations.isEmpty else { continue }
            outcomes.actionItems.append(.init(
                text: text,
                owner: belongsToUser ? "Me" : rawOwner,
                due: cleaned(item["due"]),
                isForUser: belongsToUser,
                citations: citations))
        }
        outcomes.actionItems = outcomes.userActionItems + outcomes.otherActionItems
        for raw in object["decisions"] as? [Any] ?? [] {
            if let text = cleaned(raw), !requireEvidence {
                outcomes.decisionRecords.append(.init(text: text))
                continue
            }
            guard let item = raw as? [String: Any], let text = cleaned(item["text"]) else {
                continue
            }
            let citations = resolveCitations(
                item["source_segment_ids"], sourceSegments: sourceSegments,
                meetingID: meetingID)
            guard !requireEvidence || !citations.isEmpty else { continue }
            outcomes.decisionRecords.append(.init(text: text, citations: citations))
        }
        outcomes.openQuestions = strings(object["open_questions"])
        return outcomes
    }

    private static func resolveCitations(
        _ value: Any?, sourceSegments: [String: Transcript.Segment]?,
        meetingID: Meeting.ID?
    ) -> [OutcomeSourceCitation] {
        guard let sourceSegments else { return [] }
        var seen: Set<String> = []
        return (value as? [Any] ?? []).compactMap { raw in
            guard let id = cleaned(raw), !seen.contains(id),
                  let segment = sourceSegments[id] else { return nil }
            seen.insert(id)
            return OutcomeSourceCitation(
                meetingID: meetingID,
                segmentID: id,
                start: segment.start,
                end: segment.end,
                speaker: segment.speaker,
                excerpt: String(segment.displayText.prefix(220)))
        }
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
