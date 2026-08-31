import Foundation

enum DayDigestOverviewGenerator {
    /// Display limits for journal task copy. Sized so titles wrap and
    /// summaries stay complete sentences instead of ending on an ellipsis.
    private enum FieldLimit {
        static let titleCharacters = 160
        static let summaryWords = 120
        static let workDoneWords = 80
        static let bulletCharacters = 1_200
    }

    private struct FocusDraft: Decodable {
        var substantive: Bool
        var task: String
        var workDone: String
        var status: String
        var outcome: String
        var nextStep: String
        var sourceIDs: [Int64]

        enum CodingKeys: String, CodingKey {
            case substantive
            case task
            case workDone = "work_done"
            case status
            case outcome
            case nextStep = "next_step"
            case sourceIDs = "source_ids"
        }
    }

    private struct ParsedFocus {
        var block: DayDigestGeneratedFocusBlock?
        var isSubstantive: Bool
    }

    private struct DigestDraft: Decodable {
        struct Task: Decodable {
            var title: String
            var status: String
            var summary: String
            var nextStep: String
            var blockIndices: [Int]

            enum CodingKeys: String, CodingKey {
                case title
                case status
                case summary
                case nextStep = "next_step"
                case blockIndices = "block_indices"
            }
        }

        var tasks: [Task]
        var decisions: [String]
        var blockers: [String]
    }

    private struct NormalizedTask: Equatable {
        var title: String
        var status: String
        var summary: String
        var nextStep: String
        var blockIndices: [Int]
    }

    private struct FallbackActivity {
        var title: String
        var duration: TimeInterval
        var firstSeenAt: Date
    }

    private enum FocusOutputResult {
        case output(String, attempts: Int)
        case skip
        case stop
    }

    private enum FocusParseResult {
        case parsed(ParsedFocus?, attempts: Int)
        case stop
    }

    private struct AggregationResult {
        let draft: DigestDraft?
        let degraded: Bool
    }

    static func generate(
        evidence: DayDigestEvidence,
        engine: TextEngine,
        customPrompt: String,
        calendar: Calendar = .current
    ) async throws -> String {
        try await generateResult(
            evidence: evidence,
            engine: engine,
            customPrompt: customPrompt,
            calendar: calendar).summary
    }

    static func generateResult(
        evidence: DayDigestEvidence,
        engine: TextEngine,
        customPrompt: String,
        calendar: Calendar = .current
    ) async throws -> DayDigestOverviewGeneration {
        let segments = evidence.summarySegments()
        guard !segments.isEmpty else {
            return DayDigestOverviewGeneration(
                summary: fallback(evidence),
                quality: .complete)
        }
        let ranges = segments.map {
            "\(time($0.start, calendar: calendar))-\(time($0.end, calendar: calendar))"
        }.joined(separator: ",")
        lokalbotLog(
            "day digest plan model=\(engine.displayName) segments=\(segments.count) "
                + "events=\(segments.reduce(0) { $0 + $1.eventCount }) ranges=\(ranges)")

        let dateContext = [
            "Date: \(evidence.day.formatted(date: .complete, time: .omitted))",
        ]
        var substantiveBlocks: [DayDigestGeneratedFocusBlock] = []
        var fallbackBlocks: [DayDigestGeneratedFocusBlock] = []
        var degraded = false
        substantiveBlocks.reserveCapacity(segments.count)
        fallbackBlocks.reserveCapacity(segments.count)

        segmentLoop: for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let startedAt = Date()
            let focusPrompt = """
                Extract a substantive-work candidate from evidence segment \(index + 1) of \(segments.count).
                Decide eligibility from the work content, not from time spent or app usage.
                Allowed screen source IDs: \(segment.sourceIDs)

                \(segment.evidence)
                """
            let output: String
            var attempts: Int
            switch try await focusOutput(
                engine: engine,
                prompt: focusPrompt,
                context: dateContext,
                segmentIndex: index
            ) {
            case .output(let value, let count):
                output = value
                attempts = count
            case .skip:
                degraded = true
                continue segmentLoop
            case .stop:
                degraded = true
                break segmentLoop
            }
            let parsed: ParsedFocus?
            switch try await parsedFocus(
                output: output,
                attempts: attempts,
                segment: segment,
                engine: engine,
                prompt: focusPrompt,
                context: dateContext,
                segmentIndex: index
            ) {
            case .parsed(let value, let count):
                parsed = value
                attempts = count
            case .stop:
                degraded = true
                break segmentLoop
            }
            if parsed == nil { degraded = true }
            if let parsed, let block = parsed.block {
                if parsed.isSubstantive {
                    substantiveBlocks.append(block)
                } else {
                    fallbackBlocks.append(block)
                }
            }
            lokalbotLog(
                "day digest segment index=\(index + 1)/\(segments.count) "
                    + "events=\(segment.eventCount) chars=\(segment.evidence.count) "
                    + "parsed=\(parsed != nil) "
                    + "substantive=\(parsed?.isSubstantive == true) "
                    + "usable=\(parsed?.block != nil) "
                    + "attempts=\(attempts) elapsed="
                    + String(format: "%.2fs", Date().timeIntervalSince(startedAt)))
        }

        let usesBestAvailableActivity = substantiveBlocks.isEmpty
        let selectedBlocks = usesBestAvailableActivity ? fallbackBlocks : substantiveBlocks
        guard !selectedBlocks.isEmpty else {
            return DayDigestOverviewGeneration(
                summary: fallback(evidence),
                quality: degraded ? .fallback : .complete)
        }

        let aggregation = try await aggregate(
            selectedBlocks,
            usesBestAvailableActivity: usesBestAvailableActivity,
            engine: engine,
            customPrompt: customPrompt,
            context: dateContext)
        if aggregation.degraded { degraded = true }

        return DayDigestOverviewGeneration(
            summary: render(blocks: selectedBlocks, draft: aggregation.draft),
            quality: degraded ? .partial : .complete)
    }

    private static func focusOutput(
        engine: TextEngine,
        prompt: String,
        context: [String],
        segmentIndex: Int
    ) async throws -> FocusOutputResult {
        do {
            let output = try await generateFocus(
                engine: engine,
                prompt: prompt,
                context: context,
                retry: false)
            return .output(output, attempts: 1)
        } catch is CancellationError {
            throw CancellationError()
        } catch TextEngineError.outputTruncated {
            return try await retryTruncatedFocus(
                engine: engine,
                prompt: prompt,
                context: context,
                segmentIndex: segmentIndex)
        } catch {
            lokalbotLog(
                "day digest segment generation stopped index=\(segmentIndex + 1) "
                    + "error=\(error.localizedDescription)")
            return .stop
        }
    }

    private static func aggregate(
        _ blocks: [DayDigestGeneratedFocusBlock],
        usesBestAvailableActivity: Bool,
        engine: TextEngine,
        customPrompt: String,
        context: [String]
    ) async throws -> AggregationResult {
        let startedAt = Date()
        let prompt = aggregationPrompt(
            blocks: blocks,
            usesBestAvailableActivity: usesBestAvailableActivity)
        let system = usesBestAvailableActivity
            ? PromptTemplates.dayDigestFallbackSystem(custom: customPrompt)
            : PromptTemplates.dayDigestSystem(custom: customPrompt)
        let draft: DigestDraft?
        do {
            let output = try await aggregationOutput(
                engine: engine,
                system: system,
                prompt: prompt,
                context: context)
            draft = parseDigest(output)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lokalbotLog(
                "day digest task aggregation fallback error=\(error.localizedDescription)")
            draft = nil
        }
        lokalbotLog(
            "day digest task aggregation mode="
                + "\(usesBestAvailableActivity ? "best-available" : "substantive") "
                + "parsed=\(draft != nil) elapsed="
                + String(format: "%.2fs", Date().timeIntervalSince(startedAt)))
        return .init(draft: draft, degraded: draft == nil)
    }

    private static func aggregationPrompt(
        blocks: [DayDigestGeneratedFocusBlock],
        usesBestAvailableActivity: Bool
    ) -> String {
        let instruction = usesBestAvailableActivity
            ? "Retain the best grounded activity even without a concrete outcome."
            : "Rank by concrete outcome, useful progress, decision, or blocker. "
                + "Do not rank by duration or chronology."
        let heading = usesBestAvailableActivity
            ? "BEST AVAILABLE WORK OR ACTIVITY CANDIDATES:"
            : "SUBSTANTIVE WORK CANDIDATES:"
        let material = blocks.enumerated()
            .map { candidateMaterial($0.element, index: $0.offset) }
            .joined(separator: "\n")
        return """
            Build the daily recap from every accepted candidate below.
            Merge candidates for the same task and include every contributing
            candidate index in block_indices. \(instruction)

            \(heading)
            \(material)
            """
    }

    private static func aggregationOutput(
        engine: TextEngine,
        system: String,
        prompt: String,
        context: [String]
    ) async throws -> String {
        do {
            return try await engine.generate(
                system: system,
                prompt: prompt,
                context: context,
                schema: digestSchema,
                options: TextGenerationOptions(
                    maxTokens: 1_600,
                    reasoningBudgetTokens: 512,
                    temperature: 0.2))
        } catch TextEngineError.outputTruncated {
            let startedAt = Date()
            let output = try await engine.generate(
                system: system,
                prompt: digestRetryPrompt + "\n\n" + prompt,
                context: context,
                schema: digestSchema,
                options: TextGenerationOptions(
                    maxTokens: 3_200,
                    reasoningBudgetTokens: 0,
                    temperature: 0))
            lokalbotLog(
                "day digest task aggregation retry reason=output-limit elapsed="
                    + String(format: "%.2fs", Date().timeIntervalSince(startedAt)))
            return output
        }
    }

    private static func retryTruncatedFocus(
        engine: TextEngine,
        prompt: String,
        context: [String],
        segmentIndex: Int
    ) async throws -> FocusOutputResult {
        let startedAt = Date()
        do {
            let output = try await generateFocus(
                engine: engine,
                prompt: prompt,
                context: context,
                retry: true)
            lokalbotLog(
                "day digest segment retry index=\(segmentIndex + 1) "
                    + "reason=output-limit elapsed="
                    + String(format: "%.2fs", Date().timeIntervalSince(startedAt)))
            return .output(output, attempts: 2)
        } catch is CancellationError {
            throw CancellationError()
        } catch TextEngineError.outputTruncated {
            lokalbotLog(
                "day digest segment retry exhausted index=\(segmentIndex + 1) "
                    + "reason=output-limit elapsed="
                    + String(format: "%.2fs", Date().timeIntervalSince(startedAt)))
            return .skip
        } catch {
            lokalbotLog(
                "day digest segment generation stopped index=\(segmentIndex + 1) "
                    + "error=\(error.localizedDescription)")
            return .stop
        }
    }

    private static func generateFocus(
        engine: TextEngine,
        prompt: String,
        context: [String],
        retry: Bool
    ) async throws -> String {
        try await engine.generate(
            system: PromptTemplates.dayDigestFocusSystem,
            prompt: retry ? focusRetryPrompt + "\n\n" + prompt : prompt,
            context: context,
            schema: focusSchema,
            options: retry
                ? TextGenerationOptions(
                    maxTokens: 1_600,
                    reasoningBudgetTokens: 0,
                    temperature: 0)
                : TextGenerationOptions(
                    maxTokens: 768,
                    reasoningBudgetTokens: 256,
                    temperature: 0.2))
    }

    private static func parsedFocus(
        output: String,
        attempts: Int,
        segment: DayDigestSummarySegment,
        engine: TextEngine,
        prompt: String,
        context: [String],
        segmentIndex: Int
    ) async throws -> FocusParseResult {
        let parsed = parseFocus(output, segment: segment)
        logFocusParsePreview(output, parsed: parsed, index: segmentIndex, retry: false)
        guard parsed == nil, attempts == 1 else {
            return .parsed(parsed, attempts: attempts)
        }
        return try await retryFocusParse(
            engine: engine,
            prompt: prompt,
            context: context,
            segment: segment,
            segmentIndex: segmentIndex)
    }

    private static func retryFocusParse(
        engine: TextEngine,
        prompt: String,
        context: [String],
        segment: DayDigestSummarySegment,
        segmentIndex: Int
    ) async throws -> FocusParseResult {
        let startedAt = Date()
        do {
            let output = try await generateFocus(
                engine: engine,
                prompt: prompt,
                context: context,
                retry: true)
            let parsed = parseFocus(output, segment: segment)
            logFocusParsePreview(output, parsed: parsed, index: segmentIndex, retry: true)
            lokalbotLog(
                "day digest segment retry index=\(segmentIndex + 1) parsed=\(parsed != nil) "
                    + "elapsed="
                    + String(format: "%.2fs", Date().timeIntervalSince(startedAt)))
            return .parsed(parsed, attempts: 2)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lokalbotLog(
                "day digest segment retry index=\(segmentIndex + 1) error="
                    + error.localizedDescription)
            return isServerUnreachable(error) ? .stop : .parsed(nil, attempts: 2)
        }
    }

    private static func logFocusParsePreview(
        _ output: String,
        parsed: ParsedFocus?,
        index: Int,
        retry: Bool
    ) {
        guard parsed == nil,
              ProcessInfo.processInfo.environment["LOKALBOT_DIGEST_DEBUG_OUTPUT"] == "1"
        else { return }
        let preview = PromptContextSanitizer.sanitize(output, maxCharacters: 800)
        let label = retry ? "retry parse preview" : "parse preview"
        lokalbotLog("day digest \(label) index=\(index + 1): \(preview)")
    }

    private static func isServerUnreachable(_ error: Error) -> Bool {
        guard let engineError = error as? TextEngineError else { return false }
        if case .serverUnreachable = engineError { return true }
        return false
    }

    private static let focusRetryPrompt = """
        The previous response was truncated or failed JSON validation.
        Retry once with a compact JSON object. Do not quote or restate the evidence.
        Keep task titles complete, including identifiers such as PR numbers.
        Write work_done as complete sentences; do not end mid-sentence.
        Keep outcome under 32 words and next_step under 28 words.
        """

    private static let digestRetryPrompt = """
        The previous response was truncated. Retry once with compact JSON.
        Include every candidate, but merge candidates that belong to the same task.
        Keep titles complete, including identifiers such as PR numbers.
        Write each summary as complete sentences; do not end mid-sentence.
        Keep each next_step, decision, or blocker under 32 words.
        Do not quote or restate candidate metadata.
        """

    static func fallback(_ evidence: DayDigestEvidence) -> String {
        if evidence.isEmpty {
            return "### At a glance\n_No activity was recorded._"
        }
        let blocks = bestAvailableFallbackBlocks(evidence)
        if !blocks.isEmpty {
            return render(blocks: blocks, draft: nil)
        }
        return "### Tasks\n- **Recorded activity** — Activity was captured, but the available context did not identify a more specific item."
    }

    /// Last-resort output for engine failures or evidence that every model
    /// pass rejected. Prefer meeting content, then the most sustained named
    /// activity contexts. This path stays deliberately conservative: it names
    /// what was present without inventing an accomplishment or outcome.
    private static func bestAvailableFallbackBlocks(
        _ evidence: DayDigestEvidence,
        limit: Int = 6
    ) -> [DayDigestGeneratedFocusBlock] {
        guard limit > 0 else { return [] }
        var blocks = fallbackMeetingBlocks(evidence.meetings, limit: limit)
        guard blocks.count < limit else { return blocks }
        appendFallbackActivities(
            fallbackActivities(from: evidence),
            to: &blocks,
            limit: limit)
        return blocks
    }

    private static func fallbackMeetingBlocks(
        _ meetings: [DayDigestMeetingEvidence],
        limit: Int
    ) -> [DayDigestGeneratedFocusBlock] {
        meetings.prefix(limit).map { meeting in
            let title = cleanInline(meeting.title, maxCharacters: FieldLimit.titleCharacters)
            let workDone = fallbackMeetingSummary(meeting)
            return DayDigestGeneratedFocusBlock(
                task: title.isEmpty ? "Recorded meeting" : title,
                workDone: workDone.isEmpty ? "Participated in the recorded meeting." : workDone,
                status: "unknown",
                outcome: cleanSummary(meeting.outcomes, maxWords: 32),
                nextStep: "",
                sourceIDs: [])
        }
    }

    private static func fallbackActivities(
        from evidence: DayDigestEvidence
    ) -> [FallbackActivity] {
        var grouped: [String: FallbackActivity] = [:]
        for activity in evidence.activities {
            guard let title = fallbackActivityTitle(
                activity.title,
                app: activity.app
            ) else { continue }
            let key = normalizedTaskKey(title)
            let duration = max(0, activity.end.timeIntervalSince(activity.start))
            if var existing = grouped[key] {
                existing.duration += duration
                existing.firstSeenAt = min(existing.firstSeenAt, activity.start)
                grouped[key] = existing
            } else {
                grouped[key] = FallbackActivity(
                    title: title,
                    duration: duration,
                    firstSeenAt: activity.start)
            }
        }
        for context in evidence.standaloneContexts {
            guard let title = fallbackActivityTitle(
                context.windowTitle,
                app: context.app
            ) else { continue }
            let key = normalizedTaskKey(title)
            if grouped[key] == nil {
                grouped[key] = FallbackActivity(
                    title: title,
                    duration: 0,
                    firstSeenAt: context.capturedAt)
            }
        }
        return grouped.values.sorted { lhs, rhs in
            if lhs.duration == rhs.duration { return lhs.firstSeenAt < rhs.firstSeenAt }
            return lhs.duration > rhs.duration
        }
    }

    private static func appendFallbackActivities(
        _ activities: [FallbackActivity],
        to blocks: inout [DayDigestGeneratedFocusBlock],
        limit: Int
    ) {
        var existingKeys = Set(blocks.map { normalizedTaskKey($0.task) })
        for activity in activities {
            let key = normalizedTaskKey(activity.title)
            guard !existingKeys.contains(key) else { continue }
            existingKeys.insert(key)
            blocks.append(DayDigestGeneratedFocusBlock(
                task: activity.title,
                workDone: "Activity related to this item was recorded; no more specific outcome was visible.",
                status: "unknown",
                outcome: "",
                nextStep: "",
                sourceIDs: []))
            if blocks.count == limit { break }
        }
    }

    private static func fallbackMeetingSummary(
        _ meeting: DayDigestMeetingEvidence
    ) -> String {
        if let tldr = markdownSection(named: "TL;DR", in: meeting.sourceSummary) {
            let clean = cleanSummary(tldr, maxWords: FieldLimit.workDoneWords)
            if !clean.isEmpty { return clean }
        }
        let outcomes = cleanSummary(meeting.outcomes, maxWords: FieldLimit.workDoneWords)
        if !outcomes.isEmpty { return outcomes }
        return ""
    }

    private static func markdownSection(named name: String, in markdown: String) -> String? {
        guard let heading = markdown.range(
            of: "## \(name)",
            options: .caseInsensitive
        ) else { return nil }
        let remainder = markdown[heading.upperBound...]
        let end = remainder.range(of: "\n## ")?.lowerBound ?? remainder.endIndex
        return String(remainder[..<end])
    }

    private static func fallbackActivityTitle(_ raw: String, app: String) -> String? {
        var title = cleanInline(raw, maxCharacters: 120)
        let cleanApp = cleanInline(app, maxCharacters: 72)
        if !cleanApp.isEmpty,
           let suffix = title.range(
               of: " - \(cleanApp)",
               options: [.caseInsensitive, .backwards]
           ) {
            title = String(title[..<suffix.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalized = title.lowercased()
        let normalizedApp = cleanApp.lowercased()
        let genericTitles: Set<String> = [
            "", "home", "login", "login window", "loginwindow", "new tab", "timeline", "today",
            "unknown",
        ]
        guard !genericTitles.contains(normalized),
              normalizedApp != "loginwindow",
              normalized != normalizedApp else { return nil }
        return cleanInline(title, maxCharacters: FieldLimit.titleCharacters)
    }

    private static var focusSchema: JSONObject {
        [
            "type": "object",
            "properties": [
                "substantive": ["type": "boolean"],
                "task": ["type": "string"],
                "work_done": ["type": "string"],
                "status": [
                    "type": "string",
                    "enum": ["completed", "in_progress", "blocked", "unknown"],
                ],
                "outcome": ["type": "string"],
                "next_step": ["type": "string"],
                "source_ids": [
                    "type": "array",
                    "items": ["type": "integer"],
                    "maxItems": 2,
                ],
            ],
            "required": [
                "substantive", "task", "work_done", "status", "outcome",
                "next_step", "source_ids",
            ],
            "additionalProperties": false,
        ]
    }

    private static var digestSchema: JSONObject {
        [
            "type": "object",
            "properties": [
                "tasks": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "status": [
                                "type": "string",
                                "enum": [
                                    "completed", "in_progress", "blocked", "unknown",
                                ],
                            ],
                            "summary": ["type": "string"],
                            "next_step": ["type": "string"],
                            "block_indices": [
                                "type": "array",
                                "items": ["type": "integer"],
                                "minItems": 1,
                            ],
                        ],
                        "required": [
                            "title", "status", "summary", "next_step", "block_indices",
                        ],
                        "additionalProperties": false,
                    ],
                    "maxItems": 8,
                ],
                "decisions": [
                    "type": "array",
                    "items": ["type": "string"],
                    "maxItems": 4,
                ],
                "blockers": [
                    "type": "array",
                    "items": ["type": "string"],
                    "maxItems": 4,
                ],
            ],
            "required": ["tasks", "decisions", "blockers"],
            "additionalProperties": false,
        ]
    }

    private static func parseFocus(
        _ output: String,
        segment: DayDigestSummarySegment
    ) -> ParsedFocus? {
        guard let json = ChatPrompt.extractJSONObject(strippingReasoning(output)),
              let data = json.data(using: .utf8),
              let draft = try? JSONDecoder().decode(FocusDraft.self, from: data) else {
            return nil
        }
        let task = cleanInline(draft.task, maxCharacters: FieldLimit.titleCharacters)
        let workDone = cleanSummary(draft.workDone, maxWords: FieldLimit.workDoneWords)
        if task.isEmpty || workDone.isEmpty {
            return draft.substantive
                ? nil
                : ParsedFocus(block: nil, isSubstantive: false)
        }
        let allowed = Set(segment.sourceIDs)
        var sourceIDs: [Int64] = []
        for id in draft.sourceIDs where allowed.contains(id) && !sourceIDs.contains(id) {
            sourceIDs.append(id)
            if sourceIDs.count == 2 { break }
        }
        return ParsedFocus(
            block: DayDigestGeneratedFocusBlock(
                task: task,
                workDone: workDone,
                status: normalizedStatus(draft.status),
                outcome: cleanSummary(draft.outcome, maxWords: 32),
                nextStep: cleanSummary(draft.nextStep, maxWords: 28),
                sourceIDs: sourceIDs),
            isSubstantive: draft.substantive)
    }

    private static func parseDigest(_ output: String) -> DigestDraft? {
        guard let json = ChatPrompt.extractJSONObject(strippingReasoning(output)),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DigestDraft.self, from: data)
    }

    private static func render(
        blocks: [DayDigestGeneratedFocusBlock],
        draft: DigestDraft?
    ) -> String {
        let normalized = normalizedDigest(draft, blocks: blocks)
        guard !normalized.tasks.isEmpty else {
            return "### Tasks\n- **Recorded activity** — Activity was captured, but the available context did not identify a more specific item."
        }

        var sections = [
            "### Tasks\n" + normalized.tasks.map(renderedTask).joined(separator: "\n"),
        ]

        let followUps = uniqueFollowUps(
            tasks: normalized.tasks,
            decisions: normalized.decisions,
            blockers: normalized.blockers)
        if !followUps.isEmpty {
            sections.append(
                "### Decisions and next steps\n"
                    + followUps.map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func normalizedDigest(
        _ draft: DigestDraft?,
        blocks: [DayDigestGeneratedFocusBlock]
    ) -> (tasks: [NormalizedTask], decisions: [String], blockers: [String]) {
        let validIndices = Set(blocks.indices)
        var tasks: [NormalizedTask] = []
        var coveredIndices: Set<Int> = []

        for raw in draft?.tasks ?? [] {
            let indices = raw.blockIndices.filter(validIndices.contains)
                .reduce(into: [Int]()) { result, index in
                    if !result.contains(index) { result.append(index) }
                }
            let title = cleanInline(raw.title, maxCharacters: FieldLimit.titleCharacters)
            let summary = cleanSummary(raw.summary, maxWords: FieldLimit.summaryWords)
            guard !indices.isEmpty, !title.isEmpty, !summary.isEmpty else { continue }
            let key = normalizedTaskKey(title)
            guard !tasks.contains(where: { normalizedTaskKey($0.title) == key }) else { continue }
            tasks.append(NormalizedTask(
                title: title,
                status: normalizedStatus(raw.status),
                summary: summary,
                nextStep: cleanSummary(raw.nextStep, maxWords: 32),
                blockIndices: indices))
            coveredIndices.formUnion(indices)
        }

        for index in blocks.indices where !coveredIndices.contains(index) {
            mergeFallbackCandidate(blocks[index], index: index, into: &tasks)
        }

        let decisions = normalizedList(draft?.decisions ?? [], maxWords: 32)
        let blockers = normalizedList(draft?.blockers ?? [], maxWords: 32)
        return (tasks, decisions, blockers)
    }

    private static func candidateMaterial(
        _ block: DayDigestGeneratedFocusBlock,
        index: Int
    ) -> String {
        """
        - [candidate_index \(index)]
          Task: \(block.task)
          Work done: \(block.workDone)
          Status: \(block.status)
          Outcome: \(block.outcome.isEmpty ? "None supported" : block.outcome)
          Next step: \(block.nextStep.isEmpty ? "None supported" : block.nextStep)
        """
    }

    private static func mergeFallbackCandidate(
        _ block: DayDigestGeneratedFocusBlock,
        index: Int,
        into tasks: inout [NormalizedTask]
    ) {
        let key = normalizedTaskKey(block.task)
        if let taskIndex = tasks.firstIndex(where: { normalizedTaskKey($0.title) == key }) {
            if !tasks[taskIndex].summary.localizedCaseInsensitiveContains(block.workDone) {
                tasks[taskIndex].summary = cleanSummary(
                    tasks[taskIndex].summary + " " + candidateSummary(block),
                    maxWords: FieldLimit.summaryWords)
            }
            if block.status != "unknown" { tasks[taskIndex].status = block.status }
            if !block.nextStep.isEmpty { tasks[taskIndex].nextStep = block.nextStep }
            tasks[taskIndex].blockIndices.append(index)
            return
        }
        tasks.append(NormalizedTask(
            title: block.task,
            status: block.status,
            summary: candidateSummary(block),
            nextStep: block.nextStep,
            blockIndices: [index]))
    }

    private static func candidateSummary(_ block: DayDigestGeneratedFocusBlock) -> String {
        var summary = block.workDone
        if !block.outcome.isEmpty,
           !summary.localizedCaseInsensitiveContains(block.outcome) {
            summary += " Outcome: \(block.outcome)"
        }
        return cleanSummary(summary, maxWords: FieldLimit.summaryWords)
    }

    private static func renderedTask(_ task: NormalizedTask) -> String {
        "- **\(task.title)** — \(statusLead(task.status))\(task.summary)"
    }

    private static func uniqueFollowUps(
        tasks: [NormalizedTask],
        decisions: [String],
        blockers: [String]
    ) -> [String] {
        var accepted: [(content: String, rendered: String)] = []
        let taskContent = tasks.map { "\($0.title) \($0.summary)" }

        func append(content: String, rendered: String) {
            guard !taskContent.contains(where: {
                DayDigestTextSimilarity.isSimilar(content, $0)
            }), !accepted.contains(where: {
                DayDigestTextSimilarity.isSimilar(content, $0.content)
            }) else { return }
            accepted.append((content, rendered))
        }

        for decision in decisions {
            append(content: decision, rendered: "Decision: \(decision)")
        }
        for blocker in blockers {
            append(content: blocker, rendered: "Blocker: \(blocker)")
        }
        for task in tasks where !task.nextStep.isEmpty {
            append(
                content: task.nextStep,
                rendered: "Next — \(task.title): \(task.nextStep)")
        }
        return accepted.map { $0.rendered }
    }

    private static func statusLead(_ status: String) -> String {
        switch status {
        case "completed": return "Completed. "
        case "in_progress": return "In progress. "
        case "blocked": return "Blocked. "
        default: return ""
        }
    }

    private static func normalizedStatus(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["completed", "in_progress", "blocked", "unknown"].contains(normalized)
            ? normalized : "unknown"
    }

    private static func normalizedTaskKey(_ value: String) -> String {
        cleanInline(value, maxCharacters: FieldLimit.titleCharacters).lowercased()
    }

    private static func normalizedList(_ values: [String], maxWords: Int) -> [String] {
        var result: [String] = []
        for raw in values {
            let clean = cleanBullet(raw, maxWords: maxWords)
            if !clean.isEmpty && !result.contains(clean) { result.append(clean) }
            if result.count == 4 { break }
        }
        return result
    }

    private static func cleanSummary(_ value: String, maxWords: Int) -> String {
        let withoutCitations = value.replacingOccurrences(
            of: #"\[screen:\d+\]"#,
            with: "",
            options: .regularExpression)
        return cleanBullet(withoutCitations, maxWords: maxWords)
    }

    private static func cleanBullet(_ value: String, maxWords: Int) -> String {
        var clean = cleanInline(value, maxCharacters: FieldLimit.bulletCharacters)
        while clean.hasPrefix("-") || clean.hasPrefix("•") {
            clean.removeFirst()
            clean = clean.trimmingCharacters(in: .whitespaces)
        }
        for prefix in ["The user ", "the user ", "User ", "user "] where clean.hasPrefix(prefix) {
            clean.removeFirst(prefix.count)
            if let first = clean.first {
                clean.replaceSubrange(clean.startIndex...clean.startIndex,
                                      with: String(first).uppercased())
            }
            break
        }
        let words = clean.split(whereSeparator: \Character.isWhitespace)
        guard words.count > maxWords else { return clean }
        return words.prefix(maxWords).joined(separator: " ") + "…"
    }

    private static func cleanInline(_ value: String, maxCharacters: Int) -> String {
        PromptContextSanitizer.sanitize(value, maxCharacters: maxCharacters)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*` "))
    }

    private static func time(_ date: Date, calendar: Calendar) -> String {
        LocalDateFormatting.time(date, calendar: calendar)
    }
}
