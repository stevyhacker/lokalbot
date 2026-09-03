import CryptoKit
import Foundation

/// Token-aware, full-transcript extraction for cited meeting outcomes.
/// Every non-empty transcript segment is included in at least one bounded
/// request; long meetings are never reduced to an uncited summary plus a
/// leading transcript prefix.
enum MeetingOutcomesGenerator {
    private static let chatEnvelopeTokens = 256
    private static let promptSafetyTokens = 1_024
    private static let outputTokens = 2_048
    private static let recoveryOutputTokens = 3_072
    private static let maximumChunkInputTokens = 6_000
    private static let boundaryOverlapUnits = 2
    private static let maximumSplitDepth = 4
    private static let checkpointVersion = 1

    struct EvidenceUnit: Equatable {
        var segmentIndex: Int
        var segmentID: String
        var line: String

        var tokenEstimate: Int {
            max(1, TokenCountEstimator.estimate(line))
        }
    }

    struct EvidenceChunk: Equatable {
        var units: [EvidenceUnit]

        var segmentIDs: [String] {
            var seen: Set<String> = []
            return units.compactMap { unit in
                guard !seen.contains(unit.segmentID) else { return nil }
                seen.insert(unit.segmentID)
                return unit.segmentID
            }
        }

        var evidence: String {
            units.map(\.line).joined(separator: "\n\n")
        }

        var prompt: String {
            OutcomesExtractor.prompt(evidence: evidence)
        }

        var tokenEstimate: Int {
            units.reduce(0) { $0 + $1.tokenEstimate }
        }
    }

    private struct Checkpoint: Codable {
        var version: Int
        var fingerprint: String
        var parts: [String: MeetingOutcomes]
    }

    static func checkpointURL(in folder: URL) -> URL {
        folder.appendingPathComponent("outcomes.parts.partial.json")
    }

    static func removeCheckpoint(in folder: URL) {
        try? FileManager.default.removeItem(at: checkpointURL(in: folder))
    }

    static func canUseSinglePass(
        transcript: Transcript,
        userSpeakerLabel: String,
        context: [String],
        contextTokens: Int,
        outputLanguage: SummaryLanguage = .matchTranscript
    ) -> Bool {
        makeChunks(
            transcript: transcript,
            userSpeakerLabel: userSpeakerLabel,
            context: context,
            contextTokens: contextTokens,
            outputLanguage: outputLanguage).count <= 1
    }

    static func makeChunks(
        transcript: Transcript,
        userSpeakerLabel: String,
        context: [String],
        contextTokens: Int,
        outputLanguage: SummaryLanguage = .matchTranscript
    ) -> [EvidenceChunk] {
        let system = OutcomesExtractor.systemPrompt(
            userSpeakerLabel: userSpeakerLabel,
            outputLanguage: outputLanguage)
        let inputBudget = chunkInputBudget(
            system: system,
            context: context,
            contextTokens: contextTokens)
        let units = evidenceUnits(transcript: transcript, targetTokens: inputBudget)
        guard !units.isEmpty else { return [] }

        var chunks: [EvidenceChunk] = []
        var current: [EvidenceUnit] = []
        var currentTokens = 0

        for unit in units {
            let unitTokens = unit.tokenEstimate
            if !current.isEmpty, currentTokens + unitTokens > inputBudget {
                chunks.append(EvidenceChunk(units: current))
                current = fittingOverlap(
                    from: current,
                    nextTokens: unitTokens,
                    budget: inputBudget)
                currentTokens = current.reduce(0) { $0 + $1.tokenEstimate }
            }
            current.append(unit)
            currentTokens += unitTokens
        }
        if !current.isEmpty {
            chunks.append(EvidenceChunk(units: current))
        }
        return chunks
    }

    static func generate(
        transcript: Transcript,
        engine: TextEngine,
        userSpeakerLabel: String,
        context: [String],
        contextTokens: Int,
        meetingID: Meeting.ID,
        checkpointURL: URL,
        outputLanguage: SummaryLanguage = .matchTranscript
    ) async throws -> MeetingOutcomes {
        let system = OutcomesExtractor.systemPrompt(
            userSpeakerLabel: userSpeakerLabel,
            outputLanguage: outputLanguage)
        let chunks = makeChunks(
            transcript: transcript,
            userSpeakerLabel: userSpeakerLabel,
            context: context,
            contextTokens: contextTokens,
            outputLanguage: outputLanguage)
        guard !chunks.isEmpty else { return MeetingOutcomes() }

        let fingerprint = checkpointFingerprint(
            chunks: chunks,
            system: system,
            context: context,
            engineName: engine.displayName)
        var checkpoint = loadCheckpoint(from: checkpointURL, matching: fingerprint)
            ?? Checkpoint(version: checkpointVersion, fingerprint: fingerprint, parts: [:])
        var parts: [MeetingOutcomes] = []
        parts.reserveCapacity(chunks.count)

        for index in chunks.indices {
            try Task.checkCancellation()
            let key = String(index)
            if let cached = checkpoint.parts[key] {
                parts.append(cached)
                lokalbotLog(
                    "meeting outcomes restored checkpoint part=\(index + 1)/\(chunks.count)")
                continue
            }

            let part = try await extractChunk(
                chunks[index],
                transcript: transcript,
                engine: engine,
                system: system,
                userSpeakerLabel: userSpeakerLabel,
                context: context,
                meetingID: meetingID,
                partIndex: index,
                partCount: chunks.count,
                depth: 0)
            parts.append(part)
            checkpoint.parts[key] = part
            saveCheckpoint(checkpoint, to: checkpointURL)
        }

        return merge(parts).prioritizingActionItems()
    }

    static func merge(_ parts: [MeetingOutcomes]) -> MeetingOutcomes {
        var actions: [MeetingOutcomes.ActionItem] = []
        var decisions: [MeetingOutcomes.Decision] = []
        var openQuestions: [String] = []

        for part in parts {
            for action in part.actionItems {
                if let index = actions.firstIndex(where: { duplicateAction($0, action) }) {
                    actions[index] = mergedAction(actions[index], action)
                } else {
                    actions.append(rebuiltAction(action))
                }
            }
            for decision in part.decisionRecords {
                if let index = decisions.firstIndex(where: { duplicateDecision($0, decision) }) {
                    decisions[index] = mergedDecision(decisions[index], decision)
                } else {
                    decisions.append(rebuiltDecision(decision))
                }
            }
            for question in part.openQuestions where !question.isEmpty {
                if !openQuestions.contains(where: { duplicateText($0, question, threshold: 0.85) }) {
                    openQuestions.append(question)
                }
            }
        }

        decisions.removeAll { decision in
            actions.contains { action in
                sharesEvidence(action.citations, decision.citations)
                    && duplicateText(action.text, decision.text, threshold: 0.65)
            }
        }
        actions.sort(by: actionOrder)
        decisions.sort(by: decisionOrder)

        var outcomes = MeetingOutcomes()
        outcomes.actionItems = actions
        outcomes.decisionRecords = decisions
        outcomes.openQuestions = openQuestions
        return outcomes
    }

    private static func extractChunk(
        _ chunk: EvidenceChunk,
        transcript: Transcript,
        engine: TextEngine,
        system: String,
        userSpeakerLabel: String,
        context: [String],
        meetingID: Meeting.ID,
        partIndex: Int,
        partCount: Int,
        depth: Int
    ) async throws -> MeetingOutcomes {
        let sourceSegments = sourceMap(for: chunk, transcript: transcript)
        var accepted: [MeetingOutcomes] = []
        var rejectedEvidence = 0
        var lastFailure: Error = TextEngineError.badResponse(
            "outcomes extraction returned no parseable JSON")

        for attempt in 0..<2 {
            try Task.checkCancellation()
            let options = attempt == 0
                ? TextGenerationOptions(
                    maxTokens: outputTokens,
                    reasoningBudgetTokens: 0,
                    temperature: 0)
                : TextGenerationOptions(
                    maxTokens: recoveryOutputTokens,
                    reasoningBudgetTokens: 0,
                    temperature: 0)
            let prompt = attempt == 0
                ? chunk.prompt
                : recoveryInstruction + "\n\n" + chunk.prompt
            do {
                let output = try await engine.generate(
                    system: system,
                    prompt: prompt,
                    context: context,
                    schema: OutcomesExtractor.schema,
                    options: options)
                guard let parsed = OutcomesExtractor.parseResult(
                    output,
                    userSpeakerLabel: userSpeakerLabel,
                    sourceSegments: sourceSegments,
                    meetingID: meetingID,
                    requireEvidence: true) else {
                    lastFailure = TextEngineError.badResponse(
                        "outcomes extraction returned invalid structured output")
                    continue
                }
                accepted.append(parsed.outcomes)
                rejectedEvidence += parsed.rejectedEvidenceCount
                if parsed.rejectedEvidenceCount == 0 {
                    return merge(accepted)
                }
                lastFailure = TextEngineError.badResponse(
                    "outcomes extraction returned unsupported citations")
            } catch is CancellationError {
                throw CancellationError()
            } catch TextEngineError.outputTruncated {
                lastFailure = TextEngineError.outputTruncated
            } catch {
                throw error
            }
        }

        if depth < maximumSplitDepth, let halves = split(chunk) {
            lokalbotLog(
                "meeting outcomes splitting part=\(partIndex + 1)/\(partCount) depth=\(depth)")
            let first = try await extractChunk(
                halves.0,
                transcript: transcript,
                engine: engine,
                system: system,
                userSpeakerLabel: userSpeakerLabel,
                context: context,
                meetingID: meetingID,
                partIndex: partIndex,
                partCount: partCount,
                depth: depth + 1)
            let second = try await extractChunk(
                halves.1,
                transcript: transcript,
                engine: engine,
                system: system,
                userSpeakerLabel: userSpeakerLabel,
                context: context,
                meetingID: meetingID,
                partIndex: partIndex,
                partCount: partCount,
                depth: depth + 1)
            return merge(accepted + [first, second])
        }

        if !accepted.isEmpty {
            lokalbotLog(
                "meeting outcomes kept grounded subset rejectedEvidence=\(rejectedEvidence) "
                    + "part=\(partIndex + 1)/\(partCount)")
            return merge(accepted)
        }
        throw lastFailure
    }

    private static func chunkInputBudget(
        system: String,
        context: [String],
        contextTokens: Int
    ) -> Int {
        let fixed = TokenCountEstimator.estimate(system)
            + context.reduce(0) { $0 + TokenCountEstimator.estimate($1) }
            + schemaTokenEstimate
            + TokenCountEstimator.estimate(OutcomesExtractor.prompt(evidence: ""))
            + chatEnvelopeTokens
            + recoveryOutputTokens
            + promptSafetyTokens
        return max(512, min(maximumChunkInputTokens, contextTokens - fixed))
    }

    private static var schemaTokenEstimate: Int {
        guard let data = try? JSONSerialization.data(
            withJSONObject: OutcomesExtractor.schema,
            options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return 512
        }
        return TokenCountEstimator.estimate(text)
    }

    private static func evidenceUnits(
        transcript: Transcript,
        targetTokens: Int
    ) -> [EvidenceUnit] {
        var units: [EvidenceUnit] = []
        for index in transcript.segments.indices {
            let segment = transcript.segments[index]
            let text = segment.displayText
            guard !text.isEmpty else { continue }
            let segmentID = transcript.segmentID(at: index)
            let prefix = "[\(segmentID)] [\(Transcript.stamp(segment.start))] "
                + "\(transcript.displaySpeaker(for: segment.speaker)): "
            let available = max(64, targetTokens - TokenCountEstimator.estimate(prefix))
            let parts = splitText(text, targetTokens: available)
            units += parts.map { part in
                EvidenceUnit(
                    segmentIndex: index,
                    segmentID: segmentID,
                    line: prefix + part)
            }
        }
        return units
    }

    private static func splitText(_ text: String, targetTokens: Int) -> [String] {
        guard TokenCountEstimator.estimate(text) > targetTokens else { return [text] }
        var parts: [String] = []
        var current = ""

        func appendCurrent() {
            guard !current.isEmpty else { return }
            parts.append(current)
            current = ""
        }

        for slice in text.split(whereSeparator: { $0.isWhitespace }) {
            var word = String(slice)
            while TokenCountEstimator.estimate(word) > targetTokens {
                appendCurrent()
                let characterLimit = max(32, targetTokens * 3)
                let splitIndex = word.index(
                    word.startIndex,
                    offsetBy: min(characterLimit, word.count))
                parts.append(String(word[..<splitIndex]))
                word = String(word[splitIndex...])
            }
            let candidate = current.isEmpty ? word : current + " " + word
            if TokenCountEstimator.estimate(candidate) > targetTokens {
                appendCurrent()
                current = word
            } else {
                current = candidate
            }
        }
        appendCurrent()
        return parts
    }

    private static func fittingOverlap(
        from units: [EvidenceUnit],
        nextTokens: Int,
        budget: Int
    ) -> [EvidenceUnit] {
        var overlap: [EvidenceUnit] = []
        var used = nextTokens
        for unit in units.suffix(boundaryOverlapUnits).reversed() {
            guard used + unit.tokenEstimate <= budget else { continue }
            overlap.insert(unit, at: 0)
            used += unit.tokenEstimate
        }
        return overlap
    }

    private static func split(
        _ chunk: EvidenceChunk
    ) -> (EvidenceChunk, EvidenceChunk)? {
        guard chunk.units.count > 1 else { return nil }
        let target = max(1, chunk.tokenEstimate / 2)
        var running = 0
        var splitIndex = 1
        for index in 0..<(chunk.units.count - 1) {
            running += chunk.units[index].tokenEstimate
            splitIndex = index + 1
            if running >= target { break }
        }
        return (
            EvidenceChunk(units: Array(chunk.units[..<splitIndex])),
            EvidenceChunk(units: Array(chunk.units[splitIndex...])))
    }

    private static func sourceMap(
        for chunk: EvidenceChunk,
        transcript: Transcript
    ) -> [String: Transcript.Segment] {
        var result: [String: Transcript.Segment] = [:]
        for unit in chunk.units where transcript.segments.indices.contains(unit.segmentIndex) {
            result[unit.segmentID] = transcript.segments[unit.segmentIndex]
        }
        return result
    }

    private static func duplicateAction(
        _ lhs: MeetingOutcomes.ActionItem,
        _ rhs: MeetingOutcomes.ActionItem
    ) -> Bool {
        guard compatibleOwners(lhs, rhs) else { return false }
        if normalized(lhs.text) == normalized(rhs.text) { return true }
        return sharesEvidence(lhs.citations, rhs.citations)
            && duplicateText(lhs.text, rhs.text, threshold: 0.65)
    }

    private static func duplicateDecision(
        _ lhs: MeetingOutcomes.Decision,
        _ rhs: MeetingOutcomes.Decision
    ) -> Bool {
        normalized(lhs.text) == normalized(rhs.text)
            || (sharesEvidence(lhs.citations, rhs.citations)
                && duplicateText(lhs.text, rhs.text, threshold: 0.65))
    }

    private static func compatibleOwners(
        _ lhs: MeetingOutcomes.ActionItem,
        _ rhs: MeetingOutcomes.ActionItem
    ) -> Bool {
        guard lhs.isForUser == rhs.isForUser else { return false }
        if lhs.isForUser { return true }
        let left = normalized(lhs.owner ?? "")
        let right = normalized(rhs.owner ?? "")
        return left.isEmpty || right.isEmpty || left == right
    }

    private static func mergedAction(
        _ lhs: MeetingOutcomes.ActionItem,
        _ rhs: MeetingOutcomes.ActionItem
    ) -> MeetingOutcomes.ActionItem {
        let isForUser = lhs.isForUser || rhs.isForUser
        return .init(
            text: preferredText(lhs.text, rhs.text),
            owner: isForUser ? "Me" : lhs.owner ?? rhs.owner,
            due: lhs.due ?? rhs.due,
            isForUser: isForUser,
            importance: max(lhs.importance, rhs.importance),
            citations: mergedCitations(lhs.citations, rhs.citations))
    }

    private static func rebuiltAction(
        _ action: MeetingOutcomes.ActionItem
    ) -> MeetingOutcomes.ActionItem {
        .init(
            text: action.text,
            owner: action.isForUser ? "Me" : action.owner,
            due: action.due,
            isForUser: action.isForUser,
            importance: action.importance,
            citations: mergedCitations(action.citations, []))
    }

    private static func mergedDecision(
        _ lhs: MeetingOutcomes.Decision,
        _ rhs: MeetingOutcomes.Decision
    ) -> MeetingOutcomes.Decision {
        .init(
            text: preferredText(lhs.text, rhs.text),
            citations: mergedCitations(lhs.citations, rhs.citations))
    }

    private static func rebuiltDecision(
        _ decision: MeetingOutcomes.Decision
    ) -> MeetingOutcomes.Decision {
        .init(
            text: decision.text,
            citations: mergedCitations(decision.citations, []))
    }

    private static func preferredText(_ lhs: String, _ rhs: String) -> String {
        rhs.count > lhs.count ? rhs : lhs
    }

    private static func mergedCitations(
        _ lhs: [OutcomeSourceCitation],
        _ rhs: [OutcomeSourceCitation]
    ) -> [OutcomeSourceCitation] {
        var byID: [String: OutcomeSourceCitation] = [:]
        for citation in lhs + rhs where byID[citation.segmentID] == nil {
            byID[citation.segmentID] = citation
        }
        return byID.values.sorted {
            if $0.start == $1.start { return $0.segmentID < $1.segmentID }
            return $0.start < $1.start
        }
    }

    private static func sharesEvidence(
        _ lhs: [OutcomeSourceCitation],
        _ rhs: [OutcomeSourceCitation]
    ) -> Bool {
        let left = Set(lhs.map(\.segmentID))
        return !left.isDisjoint(with: rhs.map(\.segmentID))
    }

    private static func duplicateText(
        _ lhs: String,
        _ rhs: String,
        threshold: Double
    ) -> Bool {
        let left = tokens(lhs)
        let right = tokens(rhs)
        let union = left.union(right)
        guard !union.isEmpty else { return false }
        let score = Double(left.intersection(right).count) / Double(union.count)
        return score >= threshold
    }

    private static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(normalized(text).split(separator: " ").map(String.init))
    }

    private static func actionOrder(
        _ lhs: MeetingOutcomes.ActionItem,
        _ rhs: MeetingOutcomes.ActionItem
    ) -> Bool {
        if lhs.isForUser != rhs.isForUser { return lhs.isForUser }
        let left = lhs.citations.first?.start ?? .infinity
        let right = rhs.citations.first?.start ?? .infinity
        if left == right { return lhs.text.localizedCaseInsensitiveCompare(rhs.text) == .orderedAscending }
        return left < right
    }

    private static func decisionOrder(
        _ lhs: MeetingOutcomes.Decision,
        _ rhs: MeetingOutcomes.Decision
    ) -> Bool {
        let left = lhs.citations.first?.start ?? .infinity
        let right = rhs.citations.first?.start ?? .infinity
        if left == right { return lhs.text.localizedCaseInsensitiveCompare(rhs.text) == .orderedAscending }
        return left < right
    }

    private static func checkpointFingerprint(
        chunks: [EvidenceChunk],
        system: String,
        context: [String],
        engineName: String
    ) -> String {
        let value = [
            "meeting-outcomes-v\(checkpointVersion)",
            engineName,
            system,
            context.joined(separator: "\n<context>\n"),
            chunks.map(\.evidence).joined(separator: "\n<chunk>\n"),
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
                "meeting outcomes checkpoint write failed error=\(error.localizedDescription)")
        }
    }

    private static let recoveryInstruction = """
        Retry compactly. Return only the complete JSON object. Use only outcomes supported by this evidence, copy cited segment IDs exactly, merge duplicates, and do not include hidden reasoning.
        """
}
