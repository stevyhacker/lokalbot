import Foundation

/// Token-aware meeting summarization with bounded recovery for models that use
/// their output allowance on reasoning or otherwise hit `finish_reason=length`.
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
    private static let checkpointVersion = 1

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
        let turns = transcript.summaryPromptTurns()
        let compactTranscript = turns.map(transcript.summaryPromptLine)
            .joined(separator: "\n\n")
        let directPrompt = PromptTemplates.userPrompt(
            transcript: compactTranscript,
            template: template,
            summaryLanguage: language,
            userSpeakerLabel: userSpeakerLabel)

        func splitSummary(forceMultipleChunks: Bool) async throws -> String {
            try await mapReduce(
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
                forceMultipleChunks: forceMultipleChunks)
        }

        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            lokalbotLog("meeting summary resuming checkpointed split extraction")
            return try await splitSummary(forceMultipleChunks: true)
        }

        if shouldUseSinglePass(
            system: systemPrompt,
            prompt: directPrompt,
            context: context,
            contextTokens: contextTokens) {
            do {
                return try await generateWithRecovery(
                    engine: engine,
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
                return try await splitSummary(forceMultipleChunks: true)
            }
        }

        lokalbotLog(
            "meeting summary using map-reduce inputTokens="
                + "\(inputTokenEstimate(system: systemPrompt, prompt: directPrompt, context: context)) "
                + "contextTokens=\(contextTokens)")
        return try await splitSummary(forceMultipleChunks: false)
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
            userSpeakerLabel: userSpeakerLabel)
        let inputBudget = chunkInputBudget(
            system: chunkSystem,
            contextTokens: contextTokens)
        let chunks = makeChunks(
            turns: turns,
            transcript: transcript,
            targetTokens: inputBudget,
            forceMultipleChunks: forceMultipleChunks)
        guard !chunks.isEmpty else {
            return "## Summary\n\nNo spoken transcript content was available."
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
            if let cached = checkpoint.notes[key] {
                notes.append(cached)
                lokalbotLog(
                    "meeting summary restored checkpoint part=\(index + 1)/\(chunks.count)")
                continue
            }
            let note = try await summarizeChunk(
                chunks[index],
                transcript: transcript,
                engine: engine,
                system: chunkSystem,
                partIndex: index,
                partCount: chunks.count,
                depth: 0)
            notes.append(note)
            checkpoint.notes[key] = note
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
        let fittedNotes = fittedNotes(notes, tokenBudget: noteTokenBudget)
        let synthesisPrompt = synthesisPrefix + fittedNotes
        do {
            return try await generateWithRecovery(
                engine: engine,
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
            return "## Consolidated notes\n\n" + fittedNotes
        }
    }

    private static func summarizeChunk(
        _ turns: [Transcript.PromptTurn],
        transcript: Transcript,
        engine: TextEngine,
        system: String,
        partIndex: Int,
        partCount: Int,
        depth: Int
    ) async throws -> String {
        let prompt = turns.map(transcript.summaryPromptLine).joined(separator: "\n\n")
        let context = [
            "Part \(partIndex + 1) of \(partCount) from a longer meeting"
                + (depth == 0 ? "." : "; recovery subpart depth \(depth)."),
        ]
        do {
            return try await generateWithRecovery(
                engine: engine,
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
                engine: engine,
                system: system,
                partIndex: partIndex,
                partCount: partCount,
                depth: depth + 1)
            let second = try await summarizeChunk(
                halves.1,
                transcript: transcript,
                engine: engine,
                system: system,
                partIndex: partIndex,
                partCount: partCount,
                depth: depth + 1)
            return first + "\n\n---\n\n" + second
        }
    }

    private static func generateWithRecovery(
        engine: TextEngine,
        system: String,
        prompt: String,
        context: [String],
        initialOptions: TextGenerationOptions,
        recoveryOptions: TextGenerationOptions,
        recoveryInstruction: String,
        stage: String
    ) async throws -> String {
        do {
            return try await engine.generate(
                system: system,
                prompt: prompt,
                context: context,
                options: initialOptions)
        } catch is CancellationError {
            throw CancellationError()
        } catch TextEngineError.outputTruncated {
            lokalbotLog("meeting summary compact retry stage=\(stage) reason=output-limit")
            do {
                return try await engine.generate(
                    system: system,
                    prompt: recoveryInstruction + "\n\n" + prompt,
                    context: context,
                    options: recoveryOptions)
            } catch is CancellationError {
                throw CancellationError()
            } catch TextEngineError.outputTruncated {
                throw RecoveryFailure.outputTruncated
            }
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

        for turn in turns {
            let tokens = max(1, TokenCountEstimator.estimate(transcript.summaryPromptLine(turn)))
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

    private static func fittedNotes(_ notes: [String], tokenBudget: Int) -> String {
        guard !notes.isEmpty else { return "No substantive notes were extracted." }
        let labelAllowance = notes.count * 12
        let contentBudget = max(notes.count, tokenBudget - labelAllowance)
        let estimates = notes.map(TokenCountEstimator.estimate)
        var allocations = Array(repeating: 0, count: notes.count)
        var pending = Set(notes.indices)
        var remaining = contentBudget

        while !pending.isEmpty {
            let share = max(1, remaining / pending.count)
            let completed = pending.filter { estimates[$0] <= share }
            if completed.isEmpty {
                for index in pending { allocations[index] = share }
                break
            }
            for index in completed {
                allocations[index] = estimates[index]
                remaining -= estimates[index]
                pending.remove(index)
            }
        }

        return notes.indices.map { index in
            "### Part \(index + 1)\n\n"
                + truncate(notes[index], toEstimatedTokens: allocations[index])
        }.joined(separator: "\n\n---\n\n")
    }

    private static func truncate(_ text: String, toEstimatedTokens limit: Int) -> String {
        guard limit > 0, TokenCountEstimator.estimate(text) > limit else { return text }
        var lower = 0
        var upper = text.count
        while lower < upper {
            let middle = lower + (upper - lower + 1) / 2
            let candidate = String(text.prefix(middle))
            if TokenCountEstimator.estimate(candidate) <= limit {
                lower = middle
            } else {
                upper = middle - 1
            }
        }
        let prefix = String(text.prefix(lower))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix + "…"
    }

    private static func deterministicExtract(
        _ turns: [Transcript.PromptTurn],
        transcript: Transcript
    ) -> String {
        turns.map { "- " + transcript.summaryPromptLine($0) }
            .joined(separator: "\n")
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
            $0.map(transcript.summaryPromptLine).joined(separator: "\n\n")
        }.joined(separator: "\n\n<part>\n\n")
        let value = [
            "meeting-summary-v\(checkpointVersion)",
            engineName,
            template.rawValue,
            language.rawValue,
            chunkSystem,
            chunkText,
        ].joined(separator: "\n<field>\n")
        return SHA256Digest.hex(of: value)
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
        Retry compactly. Return the complete requested Markdown notes with no preamble. Use terse bullets, omit repetition, and finish every required section. Do not include hidden reasoning.
        """

    private static let chunkRecoveryInstruction = """
        Retry as a compact extraction. Use short bullets only, merge duplicates, preserve supported decisions and action items, and finish the response. Do not include hidden reasoning.
        """

    private static let synthesisRecoveryInstruction = """
        Retry the synthesis compactly. Merge duplicate part notes, use terse Markdown, include every required section, and finish the response. Do not include hidden reasoning.
        """
}
