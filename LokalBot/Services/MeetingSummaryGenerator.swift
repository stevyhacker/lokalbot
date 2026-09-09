import CryptoKit
import Foundation

/// Token-aware meeting summarization with bounded recovery for truncated output
/// and invalid claims. Every generation is validated before it can be used.
/// Successful map notes are checkpointed so a retry resumes after the last
/// completed part instead of repeating expensive inference.
enum MeetingSummaryGenerator {
    static let builtInContextTokens = MainLLMRuntimePolicy.contextTokens
    static let conservativeExternalContextTokens = 16_384

    private static let promptSafetyTokens = 2_048
    private static let chatEnvelopeTokens = 256
    private static let directOutputTokens = 4_096
    private static let directRecoveryOutputTokens = 6_144
    private static let chunkOutputTokens = 2_048
    private static let chunkRecoveryOutputTokens = 3_072
    private static let maximumChunkInputTokens = 8_000
    private static let maximumSplitDepth = 4
    private static let checkpointVersion = 4

    private enum RecoveryFailure: Error {
        case outputTruncated
    }

    private struct Checkpoint: Codable {
        var version: Int
        var fingerprint: String
        var notes: [String: String]
    }

    static func contextTokenLimit(for backend: AppSettings.SummarizerBackend) -> Int {
        backend == .builtIn ? builtInContextTokens : conservativeExternalContextTokens
    }

    static func checkpointURL(in folder: URL) -> URL {
        folder.appendingPathComponent("summary.parts.partial.json")
    }

    static func removeCheckpoint(in folder: URL) {
        try? FileManager.default.removeItem(at: checkpointURL(in: folder))
    }

    static func inputTokenEstimate(
        system: String,
        prompt: String,
        context: [String]
    ) -> Int {
        TokenCountEstimator.estimate(system)
            + TokenCountEstimator.estimate(prompt)
            + context.reduce(0) { $0 + TokenCountEstimator.estimate($1) }
            + chatEnvelopeTokens
    }

    static func shouldUseSinglePass(
        system: String,
        prompt: String,
        context: [String],
        contextTokens: Int
    ) -> Bool {
        inputTokenEstimate(system: system, prompt: prompt, context: context)
            + directRecoveryOutputTokens
            + promptSafetyTokens <= contextTokens
    }

    static func generate(
        transcript: Transcript,
        engine: TextEngine,
        systemPrompt: String,
        template: NoteTemplate,
        language: SummaryLanguage,
        userSpeakerLabel: String,
        context: [String],
        contextTokens: Int,
        checkpointURL: URL
    ) async throws -> String {
        let raw = try await generateDraft(transcript: transcript, engine: engine,
            systemPrompt: systemPrompt + "\n\n" + SummaryClaimEvidence.instructions
                + "\n" + SummaryClaimEvidence.sectionInstruction(for: template),
            template: template, language: language, userSpeakerLabel: userSpeakerLabel,
            context: context, contextTokens: contextTokens, checkpointURL: checkpointURL)
        let claims = try SummaryClaimEvidence.decode(raw, transcript: transcript, template: template)
        try SummaryClaimEvidence.savePartial(claims, transcript: transcript, in: checkpointURL.deletingLastPathComponent())
        return SummaryClaimEvidence.render(claims, transcript: transcript, template: template)
    }

    private static func generateDraft(
        transcript: Transcript,
        engine: TextEngine,
        systemPrompt: String,
        template: NoteTemplate,
        language: SummaryLanguage,
        userSpeakerLabel: String,
        context: [String],
        contextTokens: Int,
        checkpointURL: URL
    ) async throws -> String {
        let turns = transcript.summaryPromptTurns()
        let compactTranscript = transcript.summaryPromptLines(turns)
            .joined(separator: "\n\n")
        let directPrompt = PromptTemplates.userPrompt(
            transcript: compactTranscript,
            template: template,
            summaryLanguage: language,
            userSpeakerLabel: userSpeakerLabel)

        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            lokalbotLog("meeting summary resuming checkpointed split extraction")
            return try await mapReduce(
                transcript: transcript,
                turns: turns,
                engine: engine,
                systemPrompt: systemPrompt,
                template: template,
                language: language,
                userSpeakerLabel: userSpeakerLabel,
                context: context,
                contextTokens: contextTokens,
                checkpointURL: checkpointURL,
                forceMultipleChunks: true)
        }

        if shouldUseSinglePass(
            system: systemPrompt,
            prompt: directPrompt,
            context: context,
            contextTokens: contextTokens) {
            do {
                return try await generateWithRecovery(
                    engine: engine,
                    transcript: transcript,
                    template: template,
                    allowedIDs: Set(turns.map(\.sourceID)),
                    system: systemPrompt,
                    prompt: directPrompt,
                    context: context,
                    initialOptions: TextGenerationOptions(
                        maxTokens: directOutputTokens,
                        reasoningBudgetTokens: 1_024,
                        temperature: 0.2),
                    recoveryOptions: TextGenerationOptions(
                        maxTokens: directRecoveryOutputTokens,
                        reasoningBudgetTokens: 0,
                        temperature: 0),
                    recoveryInstruction: directRecoveryInstruction,
                    stage: "direct")
            } catch RecoveryFailure.outputTruncated {
                lokalbotLog(
                    "meeting summary direct recovery exhausted; switching to split extraction")
                return try await mapReduce(
                    transcript: transcript,
                    turns: turns,
                    engine: engine,
                    systemPrompt: systemPrompt,
                    template: template,
                    language: language,
                    userSpeakerLabel: userSpeakerLabel,
                    context: context,
                    contextTokens: contextTokens,
                    checkpointURL: checkpointURL,
                    forceMultipleChunks: true)
            }
        }

        lokalbotLog(
            "meeting summary using map-reduce inputTokens="
                + "\(inputTokenEstimate(system: systemPrompt, prompt: directPrompt, context: context)) "
                + "contextTokens=\(contextTokens)")
        return try await mapReduce(
            transcript: transcript,
            turns: turns,
            engine: engine,
            systemPrompt: systemPrompt,
            template: template,
            language: language,
            userSpeakerLabel: userSpeakerLabel,
            context: context,
            contextTokens: contextTokens,
            checkpointURL: checkpointURL,
            forceMultipleChunks: false)
    }

    private static func mapReduce(
        transcript: Transcript,
        turns: [Transcript.PromptTurn],
        engine: TextEngine,
        systemPrompt: String,
        template: NoteTemplate,
        language: SummaryLanguage,
        userSpeakerLabel: String,
        context: [String],
        contextTokens: Int,
        checkpointURL: URL,
        forceMultipleChunks: Bool
    ) async throws -> String {
        let chunkSystem = PromptTemplates.chunkExtractionSystem(
            summaryLanguage: language,
            userSpeakerLabel: userSpeakerLabel) + "\n\n" + SummaryClaimEvidence.instructions
            + "\n" + SummaryClaimEvidence.sectionInstruction(for: template)
        let inputBudget = chunkInputBudget(
            system: chunkSystem,
            contextTokens: contextTokens)
        let chunks = makeChunks(
            turns: turns,
            transcript: transcript,
            targetTokens: inputBudget,
            forceMultipleChunks: forceMultipleChunks)
        guard !chunks.isEmpty else {
            return try SummaryClaimEvidence.encode([])
        }

        let fingerprint = checkpointFingerprint(
            chunks: chunks,
            transcript: transcript,
            chunkSystem: chunkSystem,
            engineName: engine.displayName,
            template: template,
            language: language)
        var checkpoint = loadCheckpoint(from: checkpointURL, matching: fingerprint)
            ?? Checkpoint(version: checkpointVersion, fingerprint: fingerprint, notes: [:])
        var notes: [String] = []
        notes.reserveCapacity(chunks.count)

        for index in chunks.indices {
            try Task.checkCancellation()
            let key = String(index)
            if let cached = checkpoint.notes[key],
               (try? SummaryClaimEvidence.decode(cached, transcript: transcript,
                    allowedIDs: Set(chunks[index].map(\.sourceID)), template: template)) != nil {
                notes.append(cached)
                lokalbotLog(
                    "meeting summary restored checkpoint part=\(index + 1)/\(chunks.count)")
                continue
            }
            let note = try await summarizeChunk(
                chunks[index],
                transcript: transcript,
                template: template,
                engine: engine,
                system: chunkSystem,
                partIndex: index,
                partCount: chunks.count,
                depth: 0)
            let claims = try SummaryClaimEvidence.decode(note, transcript: transcript,
                allowedIDs: Set(chunks[index].map(\.sourceID)), template: template)
            let validatedNote = try SummaryClaimEvidence.encode(claims)
            notes.append(validatedNote)
            checkpoint.notes[key] = validatedNote
            saveCheckpoint(checkpoint, to: checkpointURL)
        }

        let synthesisPrefix = "Synthesize the final "
            + template.displayName.lowercased()
            + " notes from these per-part notes:\n\n"
        let noteTokenBudget = finalNotesTokenBudget(
            system: systemPrompt,
            prefix: synthesisPrefix,
            context: context,
            contextTokens: contextTokens)
        let fittedNotes = fittedNotes(notes, transcript: transcript, tokenBudget: noteTokenBudget)
        let synthesisClaims = try SummaryClaimEvidence.decode(fittedNotes, transcript: transcript, template: template)
        let synthesisPrompt = synthesisPrefix + fittedNotes
        do {
            return try await generateWithRecovery(
                engine: engine,
                transcript: transcript,
                template: template,
                allowedIDs: Set(synthesisClaims.map(\.segmentID)),
                system: systemPrompt,
                prompt: synthesisPrompt,
                context: context,
                initialOptions: TextGenerationOptions(
                    maxTokens: directOutputTokens,
                    reasoningBudgetTokens: 1_024,
                    temperature: 0.2),
                recoveryOptions: TextGenerationOptions(
                    maxTokens: directRecoveryOutputTokens,
                    reasoningBudgetTokens: 0,
                    temperature: 0),
                recoveryInstruction: synthesisRecoveryInstruction,
                stage: "synthesis")
        } catch RecoveryFailure.outputTruncated {
            // A usable summary is better than failing the durable job after
            // every part was extracted successfully. Keep the model-authored
            // part notes under a deterministic heading and let a later manual
            // re-summarize attempt replace it if desired.
            lokalbotLog(
                "meeting summary synthesis recovery exhausted; using consolidated part notes")
            let claims = try notes.flatMap { try SummaryClaimEvidence.decode($0, transcript: transcript, template: template) }
            return try SummaryClaimEvidence.encode(claims)
        }
    }

    private static func summarizeChunk(
        _ turns: [Transcript.PromptTurn],
        transcript: Transcript,
        template: NoteTemplate,
        engine: TextEngine,
        system: String,
        partIndex: Int,
        partCount: Int,
        depth: Int
    ) async throws -> String {
        let prompt = transcript.summaryPromptLines(turns).joined(separator: "\n\n")
        let context = [
            "Part \(partIndex + 1) of \(partCount) from a longer meeting"
                + (depth == 0 ? "." : "; recovery subpart depth \(depth)."),
        ]
        do {
            return try await generateWithRecovery(
                engine: engine,
                transcript: transcript,
                template: template,
                allowedIDs: Set(turns.map(\.sourceID)),
                system: system,
                prompt: prompt,
                context: context,
                initialOptions: TextGenerationOptions(
                    maxTokens: chunkOutputTokens,
                    reasoningBudgetTokens: 512,
                    temperature: 0.2),
                recoveryOptions: TextGenerationOptions(
                    maxTokens: chunkRecoveryOutputTokens,
                    reasoningBudgetTokens: 0,
                    temperature: 0),
                recoveryInstruction: chunkRecoveryInstruction,
                stage: "part-\(partIndex + 1)-depth-\(depth)")
        } catch RecoveryFailure.outputTruncated {
            guard depth < maximumSplitDepth,
                  let halves = splitForRecovery(turns) else {
                lokalbotLog(
                    "meeting summary part recovery exhausted part=\(partIndex + 1) "
                        + "depth=\(depth); using deterministic extract")
                return deterministicExtract(turns, transcript: transcript)
            }
            lokalbotLog(
                "meeting summary splitting truncated part=\(partIndex + 1) depth=\(depth)")
            let first = try await summarizeChunk(
                halves.0,
                transcript: transcript,
                template: template,
                engine: engine,
                system: system,
                partIndex: partIndex,
                partCount: partCount,
                depth: depth + 1)
            let second = try await summarizeChunk(
                halves.1,
                transcript: transcript,
                template: template,
                engine: engine,
                system: system,
                partIndex: partIndex,
                partCount: partCount,
                depth: depth + 1)
            let claims = try [first, second].flatMap { try SummaryClaimEvidence.decode($0, transcript: transcript, template: template) }
            return try SummaryClaimEvidence.encode(claims)
        }
    }

    private static func generateWithRecovery(
        engine: TextEngine,
        transcript: Transcript,
        template: NoteTemplate,
        allowedIDs: Set<String>,
        system: String,
        prompt: String,
        context: [String],
        initialOptions: TextGenerationOptions,
        recoveryOptions: TextGenerationOptions,
        recoveryInstruction: String,
        stage: String
    ) async throws -> String {
        var retryPrompt = prompt
        var attempt = 0
        var retriedTruncation = false
        var repairedValidation = false
        var recoveryInstructions: [String] = []
        // Each failure mode gets at most one retry (three calls total). A
        // truncated response must not consume the citation repair allowance.
        while true {
            try Task.checkCancellation()
            do {
                let output = try await engine.generate(
                    system: system,
                    prompt: retryPrompt,
                    context: context,
                    schema: SummaryClaimEvidence.schema,
                    options: attempt == 0 ? initialOptions : recoveryOptions)
                try Task.checkCancellation()
                _ = try SummaryClaimEvidence.decode(output, transcript: transcript,
                    allowedIDs: allowedIDs, template: template)
                return output
            } catch is CancellationError {
                throw CancellationError()
            } catch TextEngineError.outputTruncated {
                guard !retriedTruncation else { throw RecoveryFailure.outputTruncated }
                retriedTruncation = true
                lokalbotLog("meeting summary compact retry stage=\(stage) reason=output-limit")
                recoveryInstructions.append(recoveryInstruction)
            } catch let error as SummaryClaimEvidence.ValidationError {
                lokalbotLog("meeting summary validation stage=\(stage) attempt=\(attempt + 1) "
                    + "reason=\(error.reason.rawValue) claim=\(error.claimNumber ?? 0)")
                guard !repairedValidation else { throw error }
                repairedValidation = true
                recoveryInstructions.append("""
                    Retry with corrected claims JSON. The previous response failed validation because \(error.reason.description).
                    Re-extract the claims from the evidence below. Copy one source_segment_id and its speaker_id exactly.
                    Copy each quote verbatim from that single segment, in the original language, without joining segments.
                    Use only the allowed section names. Action items are extracted separately. Omit any claim you cannot support.
                    Return a complete claims JSON object, with no Markdown or preamble.

                    """)
            }
            attempt += 1
            retryPrompt = recoveryInstructions.joined(separator: "\n\n") + "\n\n" + prompt
        }
    }

    private static func chunkInputBudget(system: String, contextTokens: Int) -> Int {
        let fixed = TokenCountEstimator.estimate(system)
            + chatEnvelopeTokens
            + chunkRecoveryOutputTokens
            + promptSafetyTokens
        return max(512, min(maximumChunkInputTokens, contextTokens - fixed))
    }

    private static func finalNotesTokenBudget(
        system: String,
        prefix: String,
        context: [String],
        contextTokens: Int
    ) -> Int {
        let fixed = inputTokenEstimate(system: system, prompt: prefix, context: context)
            + directRecoveryOutputTokens
            + promptSafetyTokens
        return max(512, contextTokens - fixed)
    }

    private static func makeChunks(
        turns: [Transcript.PromptTurn],
        transcript: Transcript,
        targetTokens: Int,
        forceMultipleChunks: Bool
    ) -> [[Transcript.PromptTurn]] {
        var chunks: [[Transcript.PromptTurn]] = []
        var current: [Transcript.PromptTurn] = []
        var currentTokens = 0
        let roster = transcript.speakerRoster

        for turn in turns {
            let tokens = max(1, TokenCountEstimator.estimate(transcript.summaryPromptLine(turn, roster: roster)))
            if currentTokens + tokens > targetTokens, !current.isEmpty {
                chunks.append(current)
                current = []
                currentTokens = 0
            }
            current.append(turn)
            currentTokens += tokens
        }
        if !current.isEmpty { chunks.append(current) }

        if forceMultipleChunks, chunks.count == 1,
           let halves = splitForRecovery(chunks[0]) {
            return [halves.0, halves.1]
        }
        return chunks
    }

    private static func splitForRecovery(
        _ turns: [Transcript.PromptTurn]
    ) -> ([Transcript.PromptTurn], [Transcript.PromptTurn])? {
        guard !turns.isEmpty else { return nil }
        if turns.count == 1 {
            let words = turns[0].text.split(whereSeparator: { $0.isWhitespace })
            guard words.count > 1 else { return nil }
            let middle = words.count / 2
            var first = turns[0]
            var second = turns[0]
            first.text = words[..<middle].joined(separator: " ")
            second.text = words[middle...].joined(separator: " ")
            return ([first], [second])
        }

        let estimates = turns.map { max(1, TokenCountEstimator.estimate($0.text)) }
        let target = estimates.reduce(0, +) / 2
        var running = 0
        var splitIndex = 1
        for index in 0..<(turns.count - 1) {
            running += estimates[index]
            splitIndex = index + 1
            if running >= target { break }
        }
        return (Array(turns[..<splitIndex]), Array(turns[splitIndex...]))
    }

    private static func fittedNotes(_ notes: [String], transcript: Transcript, tokenBudget: Int) -> String {
        let parts = notes.map { note in
            (try? JSONDecoder().decode(SummaryClaimEvidence.Envelope.self, from: Data(note.utf8)).claims) ?? []
        }
        var selected: [SummaryClaimEvidence.Claim] = []
        // Allocate complete claim records across all parts. Truncating raw
        // Markdown/JSON would separate a paraphrase from its speaker and quote.
        for index in 0..<(parts.map(\.count).max() ?? 0) {
            for part in parts where part.indices.contains(index) {
                let candidate = selected + [part[index]]
                guard let encoded = try? SummaryClaimEvidence.encodeForPrompt(candidate, transcript: transcript),
                      TokenCountEstimator.estimate(encoded) <= tokenBudget else { continue }
                selected = candidate
            }
        }
        return (try? SummaryClaimEvidence.encodeForPrompt(selected, transcript: transcript)) ?? "{\"claims\":[]}"
    }

    private static func deterministicExtract(
        _ turns: [Transcript.PromptTurn],
        transcript: Transcript
    ) -> String {
        let sourceMap = transcript.segmentSourceMap
        let claims = Set(turns.map(\.sourceID)).sorted().compactMap { id -> SummaryClaimEvidence.Claim? in
            guard let segment = sourceMap[id], !segment.displayText.isEmpty else { return nil }
            let quote = String(segment.displayText.prefix(600))
            return .init(section: "TL;DR", text: quote,
                speakerID: Transcript.canonicalSpeakerKey(segment.speaker), segmentID: id, quote: quote)
        }
        return (try? SummaryClaimEvidence.encode(claims)) ?? "{\"claims\":[]}"
    }

    private static func checkpointFingerprint(
        chunks: [[Transcript.PromptTurn]],
        transcript: Transcript,
        chunkSystem: String,
        engineName: String,
        template: NoteTemplate,
        language: SummaryLanguage
    ) -> String {
        let chunkText = chunks.map {
            transcript.summaryPromptLines($0).joined(separator: "\n\n")
        }.joined(separator: "\n\n<part>\n\n")
        let value = [
            "meeting-summary-v\(checkpointVersion)",
            engineName,
            transcript.evidenceRevision,
            template.rawValue,
            language.rawValue,
            chunkSystem,
            chunkText,
        ].joined(separator: "\n<field>\n")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func loadCheckpoint(
        from url: URL,
        matching fingerprint: String
    ) -> Checkpoint? {
        guard let data = try? Data(contentsOf: url),
              let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: data),
              checkpoint.version == checkpointVersion,
              checkpoint.fingerprint == fingerprint else { return nil }
        return checkpoint
    }

    private static func saveCheckpoint(_ checkpoint: Checkpoint, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(checkpoint).write(to: url, options: .atomic)
        } catch {
            lokalbotLog(
                "meeting summary checkpoint write failed error=\(error.localizedDescription)")
        }
    }

    private static let directRecoveryInstruction = """
        Retry compactly. Return complete claims JSON with source references and no preamble. Use concise claim text and omit repetition. Do not include hidden reasoning.
        """

    private static let chunkRecoveryInstruction = """
        Retry as a compact extraction. Return complete claims JSON with short supported claims and citations. Merge duplicates; action items are extracted separately. Do not include hidden reasoning.
        """

    private static let synthesisRecoveryInstruction = """
        Retry the synthesis compactly. Merge duplicate part notes, use complete claim JSON with citations, include every required section, and finish the response. Do not include hidden reasoning.
        """
}
