import CryptoKit
import Foundation

/// One transcript scan produces facts, actions, decisions and questions. There
/// is no recursive recovery or second full-transcript outcomes/synthesis pass.
enum MeetingNotesGenerator {
    struct Result {
        var claims: [SummaryClaimEvidence.Claim]
        var outcomes: MeetingOutcomes
        var body: String
    }

    struct Incomplete: LocalizedError {
        var completed: Int
        var total: Int
        var errorDescription: String? {
            "Partial notes saved (\(completed) of \(total) parts verified). Summarize again to continue."
        }
    }

    private struct Part: Codable {
        var claims: [SummaryClaimEvidence.Claim] = []
        var outcomes = MeetingOutcomes()
        var complete = false
    }
    private struct Checkpoint: Codable {
        var version = 1
        var fingerprint: String
        var parts: [String: Part] = [:]
    }

    static func checkpointURL(in folder: URL) -> URL { folder.appendingPathComponent("notes.parts.partial.json") }

    static func removeCheckpoint(in folder: URL) {
        for file in ["notes.parts.partial.json", "summary.partial.md", "outcomes.partial.json"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
    }

    static func systemPrompt(template: NoteTemplate, language: SummaryLanguage) -> String {
        PromptTemplates.meetingNotesSystem(template: template, language: language)
    }

    /// Model tokenization includes all prompt text. Providers without a native
    /// tokenizer use UTF-8 bytes as a conservative upper bound, plus envelope
    /// and structured-output headroom; punctuation/numerals are never dropped.
    static func tokenCount(_ text: String, engine: TextEngine) async throws -> Int {
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await engine.tokenCount(text) ?? text.utf8.count
        await MeetingGenerationBudget.current?.recordPhase("tokenization", seconds: ProcessInfo.processInfo.systemUptime - started)
        return max(1, result)
    }

    static func prompt(units: [MeetingNotesEvidence.Unit], roster: String) -> String {
        let commitments = Array(Set(units.filter(\.isUserCommitment).map(\.source))).sorted()
        let priority = commitments.isEmpty ? "" : "\nExplicit user commitments: \(commitments.joined(separator: ", ")). "
            + "Include these actions; use nearby context to resolve what the user accepted.\n"
        return "Speaker roster: \(roster)\(priority)\nEvidence rows are source|speaker|spoken text:\n"
            + units.map(\.line).joined(separator: "\n")
    }

    static func makeChunks(evidence: MeetingNotesEvidence, engine: TextEngine, system: String,
                           context: [String], contextTokens: Int) async throws -> [[MeetingNotesEvidence.Unit]] {
        guard !evidence.units.isEmpty else { return [] }
        let ceiling = min(6_000, contextTokens - 4_096 - 1_536)
        let fixed = ([system] + context).joined(separator: "\n\n") + "\n\n"
        var chunks: [[MeetingNotesEvidence.Unit]] = []
        var start = 0
        while start < evidence.units.count {
            try Task.checkCancellation()
            var end = evidence.units.count
            while true {
                let units = Array(evidence.units[start..<end])
                let count = try await tokenCount(fixed + prompt(units: units, roster: evidence.roster), engine: engine)
                if count <= ceiling { chunks.append(units); break }
                guard end > start + 1 else {
                    throw TextEngineError.badResponse("meeting context cannot fit the model's input allowance")
                }
                let fraction = max(0.1, min(0.9, Double(max(1, ceiling)) / Double(count) * 0.9))
                end = start + max(1, Int(Double(end - start) * fraction))
            }
            if end == evidence.units.count { break }
            // Two source turns retain context at boundaries without restarting
            // extraction. A tiny chunk must still advance.
            start = max(start + 1, end - 2)
        }
        return chunks
    }

    static func generate(transcript: Transcript, engine: TextEngine, template: NoteTemplate,
                         language: SummaryLanguage, context: [String], contextTokens: Int,
                         meetingID: UUID, folder: URL,
                         budget: MeetingGenerationBudget = MeetingGenerationBudget()) async throws -> Result {
        // The pipeline installs the allowance before model preparation; direct
        // callers (including offline replays) get the same deadline here.
        if MeetingGenerationBudget.current == nil {
            do {
                let result = try await budget.run {
                    try await generate(transcript: transcript, engine: engine, template: template,
                        language: language, context: context, contextTokens: contextTokens,
                        meetingID: meetingID, folder: folder, budget: budget)
                }
                await budget.saveMetrics(in: folder, outcome: "complete")
                return result
            } catch {
                await budget.saveMetrics(in: folder, outcome: "incomplete")
                throw error
            }
        }
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let system = systemPrompt(template: template, language: language)
        let chunks = try await makeChunks(evidence: evidence, engine: engine, system: system,
                                          context: context, contextTokens: contextTokens)
        let fingerprintText = (["notes-v1", transcript.evidenceRevision, engine.displayName, system,
                                PromptTemplates.meetingNotesRepairSystem(language: language)]
            + context + chunks.map { prompt(units: $0, roster: evidence.roster) }).joined(separator: "\n\n")
        let fingerprint = SHA256.hash(data: Data(fingerprintText.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = checkpointURL(in: folder)
        var checkpoint = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Checkpoint.self, from: $0) }
            .flatMap { $0.version == 1 && $0.fingerprint == fingerprint ? $0 : nil }
            ?? Checkpoint(fingerprint: fingerprint)

        func save() throws {
            let encoder = JSONEncoder()
            try encoder.encode(checkpoint).write(to: url, options: .atomic)
            let result = merged(checkpoint, transcript: transcript, template: template)
            try SummaryClaimEvidence.savePartial(result.claims, transcript: transcript, in: folder)
            let complete = checkpoint.parts.values.filter(\.complete).count
            let partial = "# Partial notes — \(complete)/\(chunks.count) parts verified\n\n" + result.body
            try Data(partial.utf8).write(to: folder.appendingPathComponent("summary.partial.md"), options: .atomic)
            try encoder.encode(result.outcomes).write(to: folder.appendingPathComponent("outcomes.partial.json"), options: .atomic)
        }

        for index in chunks.indices {
            try Task.checkCancellation()
            let key = String(index)
            if checkpoint.parts[key]?.complete == true { continue }
            let allowance = try await budget.allowance(remainingParts: chunks.count - index)
            let maximumNotes = min(12, max(3, allowance / 200))
            let maximumActions = min(10, max(2, allowance / 250))
            let units = chunks[index]
            let raw = try await request(engine: engine, system: system,
                prompt: prompt(units: units, roster: evidence.roster), context: context,
                schema: MeetingNotesEvidence.schema(units: units, speakers: Array(evidence.speakers.keys),
                    template: template, maximumNotes: maximumNotes, maximumActions: maximumActions),
                tokens: allowance, stage: "extract-\(index + 1)", budget: budget)
            let validationStarted = ProcessInfo.processInfo.systemUptime
            var validated = evidence.validate(raw.content, units: units, template: template, meetingID: meetingID,
                                              maximumNotes: maximumNotes, maximumActions: maximumActions)
            if validated.complete && !raw.truncated {
                let cited = Set(validated.outcomes.userActionItems.flatMap { $0.citations.map(\.segmentID) })
                let rejected = Set(validated.rejected.flatMap(\.sources))
                for unit in units where unit.isUserCommitment && !rejected.contains(unit.source) {
                    if let stable = transcript.summaryCitationSources[unit.source], !cited.contains(stable) {
                        validated.rejected.append(.init(sources: [unit.source], kind: "actions", reason: "missing_user_commitment"))
                    }
                }
                // An empty extraction cannot certify a substantial part as
                // covered. Keep it incomplete instead of silently losing it.
                if validated.claims.isEmpty && validated.outcomes.actionItems.isEmpty,
                   units.reduce(0, { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }) > 500 {
                    validated.complete = false
                }
            }
            await recordValidation(validated, stage: "extract-\(index + 1)", truncated: raw.truncated, budget: budget)
            var part = checkpoint.parts[key] ?? Part()
            part.claims = distinctClaims(part.claims + validated.claims)
            part.outcomes = MeetingOutcomesGenerator.merge([part.outcomes, validated.outcomes])
            part.complete = validated.complete && !raw.truncated && validated.rejected.isEmpty
            checkpoint.parts[key] = part
            try save() // Every accepted record survives a failure in the repair.
            await budget.recordPhase("validation", seconds: ProcessInfo.processInfo.systemUptime - validationStarted)

            // These are unsupported claims, not formatting/citation defects.
            // Do not ask the model to manufacture evidence to rescue them.
            let terminalReasons: Set<String> = ["unsupported_commitment", "conversation_management", "status_not_task", "empty_outcome"]
            let repairable = validated.rejected.filter { !terminalReasons.contains($0.reason) }
            let rejectedIDs = Set(repairable.flatMap(\.sources))
            let knownRejectedIDs = rejectedIDs.intersection(Set(units.map(\.source)))
            let rejectedIndices = units.indices.filter { rejectedIDs.contains(units[$0].source) }
            let actionSources = Set(repairable.filter { $0.kind == "actions" }.flatMap(\.sources))
            let repairIndices = Set(rejectedIndices.flatMap { index in
                let radius = actionSources.contains(units[index].source) ? 8 : 2
                return max(0, index - radius)...min(units.count - 1, index + radius)
            })
            let repairUnits = units.indices.filter { repairIndices.contains($0) }.map { units[$0] }
            if !repairUnits.isEmpty {
                let noteLimit = min(maximumNotes, repairable.filter { $0.kind == "notes" }.count)
                let actionLimit = min(maximumActions, repairable.filter { $0.kind == "actions" }.count)
                let repairTokens = try await budget.allowance(remainingParts: chunks.count - index,
                    desired: min(2_048, 512 + (noteLimit + actionLimit) * 128))
                let feedback = repairable.map { rejection in
                    ["kind": rejection.kind, "reason": rejection.reason,
                     "sources": rejection.sources.filter { knownRejectedIDs.contains($0) }.joined(separator: ", ")]
                }
                let feedbackJSON = String(decoding: try JSONSerialization.data(withJSONObject: feedback), as: UTF8.self)
                let repairPrompt = "This is a targeted repair, not a new meeting summary. "
                    + "Repair at most \(noteLimit) notes and \(actionLimit) actions from the rejected sources \(knownRejectedIDs.sorted().joined(separator: ", ")). "
                    + "Return empty arrays for unrequested kinds. Do not add a TL;DR or unrelated facts from neighboring context. "
                    + "Previously verified records are retained. Omit unsupported records. "
                    + "An unsupported_commitment means no explicit undertaking exists in that source. "
                    + "For missing_user_commitment, extract the user's undertaking and use its nearest relevant task context. "
                    + "Do not return completed work as a task. Preserve requests or suggestions as such, never as commitments. "
                    + "Remove conversation management and status-only reports. For distant_action_context, cite only sources within eight segments of the primary source. "
                    + "has_more refers only to these requested repairs, not to unrelated evidence.\n"
                    + "Validation feedback: \(feedbackJSON)\n"
                    + prompt(units: repairUnits, roster: evidence.roster)
                let repaired = try await request(engine: engine,
                    system: PromptTemplates.meetingNotesRepairSystem(language: language), prompt: repairPrompt, context: [],
                    schema: MeetingNotesEvidence.schema(units: repairUnits, speakers: Array(evidence.speakers.keys),
                        template: template, maximumNotes: noteLimit, maximumActions: actionLimit),
                    tokens: repairTokens, stage: "repair-\(index + 1)", budget: budget)
                let started = ProcessInfo.processInfo.systemUptime
                let fixed = evidence.validate(repaired.content, units: repairUnits, template: template, meetingID: meetingID,
                                              maximumNotes: noteLimit, maximumActions: actionLimit)
                await recordValidation(fixed, stage: "repair-\(index + 1)", truncated: repaired.truncated, budget: budget)
                part.claims = distinctClaims(part.claims + fixed.claims)
                part.outcomes = MeetingOutcomesGenerator.merge([part.outcomes, fixed.outcomes])
                // Rejected records are omitted after one repair. They do not
                // undo a complete scan or erase its independently valid facts.
                part.complete = validated.complete && !raw.truncated && fixed.complete && !repaired.truncated
                await budget.recordPhase("validation", seconds: ProcessInfo.processInfo.systemUptime - started)
            } else if repairable.isEmpty {
                part.complete = validated.complete && !raw.truncated
            }
            // Critical user follow-ups may not silently disappear with the
            // rejected records. Keep this part resumable if repair missed one.
            let cited = Set(part.outcomes.userActionItems.flatMap { $0.citations.map(\.segmentID) })
            if units.contains(where: { unit in
                unit.isUserCommitment && transcript.summaryCitationSources[unit.source].map { !cited.contains($0) } == true
            }) { part.complete = false }
            checkpoint.parts[key] = part
            try save()
        }
        let completed = checkpoint.parts.values.filter(\.complete).count
        guard completed == chunks.count else { throw Incomplete(completed: completed, total: chunks.count) }
        let result = merged(checkpoint, transcript: transcript, template: template)
        try SummaryClaimEvidence.savePartial(result.claims, transcript: transcript, in: folder)
        return result
    }

    private static func request(engine: TextEngine, system: String, prompt: String, context: [String],
                                schema: [String: Any], tokens: Int, stage: String,
                                budget: MeetingGenerationBudget, attempt: Int = 0) async throws -> (content: String, truncated: Bool) {
        let input = try await tokenCount(([system] + context + [prompt]).joined(separator: "\n\n"), engine: engine) + 1_536
        return try await MeetingGenerationBudget.$stage.withValue(stage) {
            try await MeetingGenerationBudget.$promptTokens.withValue(input) {
                let reservation = engine.accountsForGenerationRequests ? nil : try await budget.reserve(input: input, output: tokens)
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    let text = try await engine.generate(system: system, prompt: prompt, context: context,
                        schema: schema, options: .init(maxTokens: tokens,
                            reasoningBudgetTokens: 0, temperature: 0))
                    if let reservation {
                        await budget.finish(reservation, metric: .init(stage: stage, outcome: "complete",
                            wallSeconds: ProcessInfo.processInfo.systemUptime - started))
                    }
                    return (text, false)
                } catch {
                    if let reservation {
                        await budget.finish(reservation, metric: .init(stage: stage,
                            outcome: error is TruncatedStructuredResponse ? "truncated" : "failed",
                            wallSeconds: ProcessInfo.processInfo.systemUptime - started))
                    }
                    if let partial = error as? TruncatedStructuredResponse { return (partial.content, true) }
                    if case TextEngineError.outputTruncated = error { return ("", true) }
                    // Managed local engines already reacquire once. External
                    // transient failures get one replay charged to this job.
                    if !(engine is LeasedTextEngine),
                       let delay = TextEngineRetryPolicy.delay(for: error, attempt: attempt) {
                        let waiting = ProcessInfo.processInfo.systemUptime
                        try await Task.sleep(for: .seconds(delay))
                        await budget.recordPhase("retryBackoff", seconds: ProcessInfo.processInfo.systemUptime - waiting)
                        return try await request(engine: engine, system: system, prompt: prompt, context: context,
                            schema: schema, tokens: tokens, stage: "retry-" + stage, budget: budget, attempt: attempt + 1)
                    }
                    throw error
                }
            }
        }
    }

    private static func distinctClaims(_ claims: [SummaryClaimEvidence.Claim]) -> [SummaryClaimEvidence.Claim] {
        var seen = Set<String>()
        return claims.filter { seen.insert("\($0.section)|\($0.speakerID)|\(OutcomeTextSimilarity.normalized($0.text))").inserted }
    }

    private static func recordValidation(_ value: MeetingNotesEvidence.Validated, stage: String,
                                         truncated: Bool, budget: MeetingGenerationBudget) async {
        let reasons = Dictionary(grouping: value.rejected, by: \.reason).mapValues(\.count)
        await budget.recordValidation(.init(stage: stage, completeEnvelope: value.complete,
            hasMore: value.hasMore, truncated: truncated, notes: value.claims.count,
            actions: value.outcomes.actionItems.count, rejections: reasons))
    }

    private static func merged(_ checkpoint: Checkpoint, transcript: Transcript, template: NoteTemplate) -> Result {
        let parts = checkpoint.parts.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.compactMap { checkpoint.parts[$0] }
        let claims = distinctClaims(parts.flatMap(\.claims))
        var renderedClaims = claims
        if !claims.contains(where: { $0.section == "TL;DR" }) {
            // Rendering already-verified facts needs no further model call.
            let overview = claims.filter { !["Decisions", "Open questions"].contains($0.section) }.prefix(3)
                .map { claim in var value = claim; value.section = "TL;DR"; return value }
            renderedClaims = overview + claims
        }
        var outcomes = MeetingOutcomesGenerator.merge(parts.map(\.outcomes)).prioritizingActionItems()
        outcomes.transcriptRevision = transcript.evidenceRevision
        let body = MeetingSummaryOutcomeSynchronizer.synchronize(
            SummaryClaimEvidence.render(renderedClaims, transcript: transcript, template: template), outcomes: outcomes, template: template)
        return Result(claims: claims, outcomes: outcomes, body: body)
    }
}
