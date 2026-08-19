import XCTest
@testable import LokalBot

final class DayDigestEvidenceTests: XCTestCase {
    private actor GenerationRecorder {
        struct Call: Equatable, Sendable {
            var isFocus: Bool
            var maxTokens: Int?
            var reasoningBudgetTokens: Int?
            var temperature: Double?
        }

        private(set) var calls: [Call] = []

        func record(isFocus: Bool, options: TextGenerationOptions) -> Int {
            calls.append(Call(
                isFocus: isFocus,
                maxTokens: options.maxTokens,
                reasoningBudgetTokens: options.reasoningBudgetTokens,
                temperature: options.temperature))
            return calls.filter { $0.isFocus == isFocus }.count
        }
    }

    private struct StructuredDigestEngine: TextEngine {
        let recorder: GenerationRecorder
        var invalidFirstFocus = false
        var alwaysInvalidFocus = false
        var truncatedFocusCalls: Set<Int> = []
        var truncatedFinalCalls: Set<Int> = []
        var invalidFinal = false
        var nonSubstantiveFocusIndices: Set<Int> = []
        var bestAvailableFocusIndices: Set<Int> = []
        var finalResponse: String?
        var displayName: String { "structured-test" }

        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            "unused"
        }

        func generate(system: String, prompt: String, context: [String],
                      schema: [String: Any],
                      options: TextGenerationOptions) async throws -> String {
            let isFocus = system == PromptTemplates.dayDigestFocusSystem
            let index = await recorder.record(isFocus: isFocus, options: options)
            if isFocus {
                if truncatedFocusCalls.contains(index) {
                    throw TextEngineError.outputTruncated
                }
                if alwaysInvalidFocus || (invalidFirstFocus && index == 1) {
                    return "not valid JSON"
                }
                if nonSubstantiveFocusIndices.contains(index) {
                    return """
                        {"substantive":false,"task":"","work_done":"","status":"unknown","outcome":"","next_step":"","source_ids":[]}
                        """
                }
                if bestAvailableFocusIndices.contains(index) {
                    return """
                        {"substantive":false,"task":"Protocol research","work_done":"Reviewed material about a protocol without reaching a visible conclusion.","status":"unknown","outcome":"","next_step":"","source_ids":[]}
                        """
                }
                return """
                    {"substantive":true,"task":"Task \(index)","work_done":"Advanced substantive work for task \(index).","status":"in_progress","outcome":"Useful progress was recorded.","next_step":"","source_ids":[]}
                    """
            }
            if truncatedFinalCalls.contains(index) {
                throw TextEngineError.outputTruncated
            }
            if invalidFinal { return "not valid JSON" }
            if let finalResponse { return finalResponse }
            return """
                {
                  "tasks": [
                    {"title":"Task 1","status":"in_progress","summary":"Advanced the first substantive task.","next_step":"","block_indices":[0]},
                    {"title":"Task 2","status":"completed","summary":"Completed the second substantive task.","next_step":"","block_indices":[1]},
                    {"title":"Task 3","status":"completed","summary":"Completed the third substantive task.","next_step":"","block_indices":[2]}
                  ],
                  "decisions": [],
                  "blockers": []
                }
                """
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var day: Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 4, hour: 12))!
    }

    private func time(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 4, hour: hour, minute: minute))!
    }

    private func block(_ id: Int64, _ hour: Int, _ title: String) -> ActivityBlock {
        ActivityBlock(
            id: id,
            app: id == 2 ? "Safari" : "Xcode",
            title: title,
            start: time(hour),
            end: time(hour, 45))
    }

    private func block(
        _ id: Int64,
        startHour: Int,
        startMinute: Int = 0,
        endHour: Int,
        endMinute: Int = 0,
        title: String,
        app: String
    ) -> ActivityBlock {
        ActivityBlock(
            id: id,
            app: app,
            title: title,
            start: time(startHour, startMinute),
            end: time(endHour, endMinute))
    }

    private func context(_ id: Int64, _ hour: Int, _ minute: Int,
                         _ text: String, app: String = "Xcode") -> DayScreenContext {
        DayScreenContext(
            snapshotID: id,
            capturedAt: time(hour, minute),
            app: app,
            windowTitle: "Work window",
            text: text)
    }

    func testDocumentListsEveryActivityBlockOnceInChronologicalOrder() {
        let blocks = [
            block(3, 17, "Release verification"),
            block(1, 9, "DayDigestEvidence.swift"),
            block(2, 13, "Issue research"),
        ]
        let contexts = [
            context(33, 17, 20, "Gatekeeper verification passed"),
            context(11, 9, 10, "Implemented the evidence builder"),
            context(22, 13, 15, "Read the failure report", app: "Safari"),
        ]
        let meeting = DayDigestMeetingEvidence(
            id: UUID(),
            title: "Launch sync",
            app: "Zoom",
            startedAt: time(15),
            endedAt: time(15, 30),
            sourceSummary: "Reviewed launch status.",
            outcomes: "Decision: ship after verification.")
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: blocks,
            screenContexts: contexts,
            meetings: [meeting],
            calendar: calendar)

        let document = evidence.renderDocument(
            summary: "### Overview\nA grounded overview.", calendar: calendar)

        XCTAssertTrue(document.contains("## Day summary"))
        XCTAssertTrue(document.contains("## Full activity log"))
        XCTAssertTrue(document.contains("## Meetings"))
        XCTAssertTrue(document.contains("## Time allocation"))
        XCTAssertEqual(occurrences(of: "DayDigestEvidence.swift", in: document), 1)
        XCTAssertEqual(occurrences(of: "Issue research", in: document), 1)
        XCTAssertEqual(occurrences(of: "Release verification", in: document), 1)
        XCTAssertTrue(document.contains("[screen:11]"))
        XCTAssertTrue(document.contains("[screen:22]"))
        XCTAssertTrue(document.contains("[screen:33]"))

        let morning = document.range(of: "DayDigestEvidence.swift")!.lowerBound
        let middle = document.range(of: "Issue research")!.lowerBound
        let evening = document.range(of: "Release verification")!.lowerBound
        XCTAssertLessThan(morning, middle)
        XCTAssertLessThan(middle, evening)

        let meetings = document.range(of: "## Meetings")!.lowerBound
        let allocation = document.range(of: "## Time allocation")!.lowerBound
        let activity = document.range(of: "## Full activity log")!.lowerBound
        XCTAssertLessThan(meetings, allocation)
        XCTAssertLessThan(allocation, activity)
    }

    func testSummaryChunksCoverBeginningMiddleAndEndWithinBudget() {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(1, 8, "Morning implementation"),
                block(2, 13, "Midday investigation"),
                block(3, 19, "Evening verification"),
            ],
            screenContexts: [
                context(1, 8, 10, String(repeating: "morning detail ", count: 30)),
                context(2, 13, 10, String(repeating: "midday detail ", count: 30)),
                context(3, 19, 10, String(repeating: "evening detail ", count: 30)),
            ],
            meetings: [],
            calendar: calendar)

        let chunks = evidence.summaryChunks(maxCharacters: 240)
        let all = chunks.joined(separator: "\n")

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 240 })
        XCTAssertTrue(all.contains("Morning implementation"))
        XCTAssertTrue(all.contains("Midday investigation"))
        XCTAssertTrue(all.contains("Evening verification"))
    }

    func testSummarySegmentsCreateHardBoundariesAcrossIdleGaps() {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(1, 8, "Morning implementation"),
                block(2, 13, "Midday investigation"),
                block(3, 19, "Evening verification"),
            ],
            screenContexts: [
                context(11, 8, 10, "morning evidence"),
                context(22, 13, 10, "midday evidence"),
                context(33, 19, 10, "evening evidence"),
            ],
            meetings: [],
            calendar: calendar)

        let segments = evidence.summarySegments(maxCharacters: 12_000)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map(\.sourceIDs), [[11], [22], [33]])
        XCTAssertTrue(segments[0].evidence.contains("Morning implementation"))
        XCTAssertTrue(segments[1].evidence.contains("Midday investigation"))
        XCTAssertTrue(segments[2].evidence.contains("Evening verification"))
    }

    func testBriefSubstantiveTaskCanOutrankLongerWork() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(
                    1,
                    startHour: 9,
                    endHour: 14,
                    title: "Main project work",
                    app: "Xcode"),
                block(
                    2,
                    startHour: 16,
                    endHour: 16,
                    endMinute: 5,
                    title: "Invoice payment",
                    app: "Safari"),
            ],
            screenContexts: [],
            meetings: [],
            calendar: calendar)

        let segments = evidence.summarySegments()
        let expectedDurations: [TimeInterval] = [5 * 60 * 60, 5 * 60]

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.activeDuration), expectedDurations)

        let recorder = GenerationRecorder()
        let finalResponse = """
            {"tasks":[{"title":"Invoice reconciliation","status":"completed","summary":"Paid the outstanding supplier invoice.","next_step":"","block_indices":[1]},{"title":"Main project","status":"in_progress","summary":"Advanced the main project implementation.","next_step":"Continue implementation.","block_indices":[0]}],"decisions":[],"blockers":[]}
            """
        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                finalResponse: finalResponse),
            customPrompt: "",
            calendar: calendar)
        let document = evidence.renderDocument(summary: overview, calendar: calendar)
        let presentation = DayDigestPresentation(markdown: document)

        XCTAssertEqual(
            presentation.focusBlocks.map(\.title),
            ["Invoice reconciliation", "Main project"])
        XCTAssertTrue(presentation.otherActivityBlocks.isEmpty)
        XCTAssertTrue(presentation.atAGlanceMarkdown.isEmpty)
        let invoice = overview.range(of: "Invoice reconciliation")!.lowerBound
        let project = overview.range(of: "Main project")!.lowerBound
        XCTAssertLessThan(invoice, project)
        XCTAssertTrue(presentation.decisionsMarkdown?.contains("Continue implementation") == true)
        XCTAssertFalse(presentation.focusBlocks[1].summaryMarkdown.contains(
            "Continue implementation"))
        XCTAssertTrue(document.contains("Invoice payment"))
    }

    func testSegmentLimitPreservesLongAndBriefSessions() {
        var briefBlocks: [ActivityBlock] = []
        for index in 0..<7 {
            briefBlocks.append(block(
                Int64(index + 2),
                startHour: 10 + index,
                endHour: 10 + index,
                endMinute: 5,
                title: "Brief task \(index + 1)",
                app: "Safari"))
        }
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(
                    1,
                    startHour: 8,
                    endHour: 8,
                    endMinute: 40,
                    title: "Main project work",
                    app: "Xcode"),
            ] + briefBlocks,
            screenContexts: [],
            meetings: [],
            calendar: calendar)

        let segments = evidence.summarySegments()

        XCTAssertEqual(segments.count, 8)
        XCTAssertEqual(segments.first?.activeDuration, 40 * 60)
        XCTAssertTrue(segments.dropFirst().allSatisfy { $0.activeDuration == 5 * 60 })
    }

    func testLongActivityReceivesBroaderScreenCoverageThanBriefActivity() {
        var longContexts: [DayScreenContext] = []
        for index in 0..<10 {
            longContexts.append(context(
                Int64(100 + index),
                9 + index / 2,
                (index % 2) * 30,
                "main project evidence \(index)"))
        }
        var briefContexts: [DayScreenContext] = []
        for index in 0..<5 {
            briefContexts.append(context(
                Int64(200 + index),
                16,
                index,
                "invoice evidence \(index)",
                app: "Safari"))
        }
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(
                    1,
                    startHour: 9,
                    endHour: 14,
                    title: "Main project work",
                    app: "Xcode"),
                block(
                    2,
                    startHour: 16,
                    endHour: 16,
                    endMinute: 5,
                    title: "Invoice payment",
                    app: "Safari"),
            ],
            screenContexts: longContexts + briefContexts,
            meetings: [],
            calendar: calendar)

        let segments = evidence.summarySegments()

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].sourceIDs.count, 10)
        XCTAssertEqual(segments[1].sourceIDs.count, 2)
        XCTAssertEqual(occurrences(of: "Screen context [screen:", in: segments[0].evidence), 10)
        XCTAssertEqual(occurrences(of: "Screen context [screen:", in: segments[1].evidence), 2)
        XCTAssertTrue(segments[0].evidence.contains("main project evidence 0"))
        XCTAssertTrue(segments[0].evidence.contains("main project evidence 9"))
        XCTAssertTrue(segments[1].evidence.contains("invoice evidence 0"))
        XCTAssertTrue(segments[1].evidence.contains("invoice evidence 4"))
    }

    func testMeetingDetailSurvivesBusySegmentSampling() {
        var blocks: [ActivityBlock] = []
        for index in 0..<24 {
            blocks.append(ActivityBlock(
                id: Int64(index + 1),
                app: "Safari",
                title: "Activity \(index)",
                start: time(9, index),
                end: time(9, index + 1)))
        }
        let meeting = DayDigestMeetingEvidence(
            id: UUID(),
            title: "Architecture sync",
            app: "Zoom",
            startedAt: time(9, 8),
            endedAt: time(9, 9),
            sourceSummary: "## TL;DR\nKept the critical meeting detail visible.",
            outcomes: "Decision: retain the meeting evidence.")
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: blocks,
            screenContexts: [],
            meetings: [meeting],
            calendar: calendar)

        let segments = evidence.summarySegments(maxSegments: 1)

        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(segments[0].evidence.contains(
            "Kept the critical meeting detail visible."))
    }

    func testOverviewGeneratorExtractsEverySegmentBeforeTaskAggregation() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(1, 8, "Morning implementation"),
                block(2, 13, "Midday investigation"),
                block(3, 19, "Evening verification"),
            ],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(recorder: recorder),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Task 1**"))
        XCTAssertTrue(overview.contains("**Task 2**"))
        XCTAssertTrue(overview.contains("**Task 3**"))
        XCTAssertFalse(overview.contains("08:00–08:45"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls.prefix(3).allSatisfy {
            $0.isFocus && $0.maxTokens == 768
                && $0.reasoningBudgetTokens == 256 && $0.temperature == 0.2
        })
        XCTAssertEqual(calls.last, GenerationRecorder.Call(
            isFocus: false,
            maxTokens: 1_600,
            reasoningBudgetTokens: 512,
            temperature: 0.2))
    }

    func testOverviewGeneratorRetriesOneInvalidFocusResponse() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 8, "Morning implementation")],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                invalidFirstFocus: true,
                invalidFinal: true),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Task 2**"))
        XCTAssertFalse(overview.localizedCaseInsensitiveContains("recorded activity"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[1], GenerationRecorder.Call(
            isFocus: true,
            maxTokens: 1_600,
            reasoningBudgetTokens: 0,
            temperature: 0))
    }

    func testOverviewGeneratorRetriesTruncatedFocusWithLargerBudget() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 8, "Morning implementation")],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                truncatedFocusCalls: [1],
                invalidFinal: true),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Task 2**"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[1], GenerationRecorder.Call(
            isFocus: true,
            maxTokens: 1_600,
            reasoningBudgetTokens: 0,
            temperature: 0))
    }

    func testOverviewGeneratorContinuesAfterTruncationRetryIsExhausted() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(1, 8, "Morning implementation"),
                block(2, 13, "Midday investigation"),
            ],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                truncatedFocusCalls: [1, 2],
                invalidFinal: true),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Task 3**"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls.last?.isFocus == false)
    }

    func testOverviewGeneratorRetriesTruncatedAggregationWithoutReasoning() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 8, "Morning implementation")],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                truncatedFinalCalls: [1]),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Task 1**"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.last, GenerationRecorder.Call(
            isFocus: false,
            maxTokens: 3_200,
            reasoningBudgetTokens: 0,
            temperature: 0))
    }

    func testBestAvailableActivityIsUsedWhenNoSubstantiveWorkIsFound() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 9, "Protocol research")],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                invalidFinal: true,
                bestAvailableFocusIndices: [1]),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Protocol research**"))
        XCTAssertTrue(overview.contains("Reviewed material about a protocol"))
        XCTAssertFalse(overview.contains("No substantive work"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testBestAvailableActivityDoesNotDiluteSubstantiveTasks() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(1, 9, "Implementation"),
                block(2, 17, "Protocol research"),
            ],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                invalidFinal: true,
                bestAvailableFocusIndices: [2]),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Task 1**"))
        XCTAssertFalse(overview.contains("Protocol research"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 3)
    }

    func testMetadataOnlySegmentUsesGenericRecordedActivityFallback() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(
                    1,
                    startHour: 9,
                    endHour: 10,
                    title: "New Tab",
                    app: "Safari"),
            ],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                nonSubstantiveFocusIndices: [1]),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Recorded activity**"))
        XCTAssertFalse(overview.contains("No substantive work"))
        XCTAssertFalse(overview.contains("Safari"))
        XCTAssertFalse(overview.contains("New Tab"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testDeterministicFallbackKeepsMeetingWorkVisible() {
        let meeting = DayDigestMeetingEvidence(
            id: UUID(),
            title: "Product standup",
            app: "Zoom",
            startedAt: time(10),
            endedAt: time(10, 30),
            sourceSummary: "## TL;DR\nReviewed deployment progress and open bugs.",
            outcomes: "Decision: keep the current deployment tool.")
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [],
            screenContexts: [],
            meetings: [meeting],
            calendar: calendar)

        let overview = DayDigestOverviewGenerator.fallback(evidence)

        XCTAssertTrue(overview.contains("**Product standup**"))
        XCTAssertTrue(overview.contains("Reviewed deployment progress"))
        XCTAssertFalse(overview.contains("No substantive work"))
    }

    func testInvalidFocusOutputFallsBackToNamedActivityWithoutAppMetadata() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 9, "Release dashboard")],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                alwaysInvalidFocus: true),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Release dashboard**"))
        XCTAssertFalse(overview.contains("No substantive work"))
        XCTAssertFalse(overview.contains("Xcode"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testAggregationGroupsSameTaskAcrossSeparateSessions() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(1, 9, "Release configuration"),
                block(2, 17, "Release verification"),
            ],
            screenContexts: [
                context(11, 9, 10, "Updated the release signing configuration."),
                context(22, 17, 10, "Gatekeeper verification passed."),
            ],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()
        let finalResponse = """
            {"tasks":[{"title":"Release pipeline","status":"completed","summary":"Updated the signing configuration and verified the resulting build with Gatekeeper.","next_step":"","block_indices":[0,1]}],"decisions":["Publish the verified build."],"blockers":[]}
            """

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                finalResponse: finalResponse),
            customPrompt: "",
            calendar: calendar)
        let document = evidence.renderDocument(summary: overview, calendar: calendar)
        let presentation = DayDigestPresentation(markdown: document)

        XCTAssertEqual(presentation.focusBlocks.count, 1)
        XCTAssertEqual(presentation.focusBlocks.first?.title, "Release pipeline")
        XCTAssertTrue(presentation.focusBlocks.first?.summaryMarkdown.contains(
            "signing configuration") == true)
        XCTAssertTrue(presentation.decisionsMarkdown?.contains("Publish") == true)
        XCTAssertFalse(overview.contains("Xcode"))
        XCTAssertFalse(overview.contains("17:00"))
    }

    func testJournalKeepsLongTaskTitlesAndCompleteSummaries() async throws {
        let title = "Oracle price-quote and price-floor logic in AggregatorSwapAdapter (PR #230)"
        let summary = """
            Implemented decimal-scaled price conversion in AggregatorSwapAdapter.sol, \
            using Math.tryMul to adjust tokenOutPrice by the tokenIn/tokenOut decimal \
            difference before deriving oracle amount-out values for a WETH/USDC quote \
            in a fork test. The changes, including the oracle price floor logic and \
            related test files, remain open as PR #230; it is unclear whether the \
            tests fully cover the new floor.
            """.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertGreaterThan(title.count, 72)
        XCTAssertGreaterThan(summary.split(whereSeparator: \.isWhitespace).count, 52)

        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 9, "AggregatorSwapAdapter")],
            screenContexts: [
                context(11, 9, 10, "Implemented oracle price conversion for PR 230."),
            ],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()
        let finalResponse = """
            {"tasks":[{"title":"\(title)","status":"in_progress","summary":"\(summary)","next_step":"","block_indices":[0]}],"decisions":[],"blockers":[]}
            """

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                finalResponse: finalResponse),
            customPrompt: "",
            calendar: calendar)
        let presentation = DayDigestPresentation(
            markdown: evidence.renderDocument(summary: overview, calendar: calendar))

        XCTAssertEqual(presentation.focusBlocks.first?.title, title)
        XCTAssertEqual(
            presentation.focusBlocks.first?.summaryMarkdown,
            "In progress. \(summary)")
        XCTAssertFalse(overview.contains("…"))
    }

    func testRendererGivesEachFactOneSectionAndDeduplicatesSimilarFollowUps() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 9, "Release pipeline")],
            screenContexts: [
                context(11, 9, 10, "Updated signing and verified the release build."),
            ],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()
        let finalResponse = """
            {"tasks":[{"title":"Release pipeline","status":"completed","summary":"Updated the signing configuration and verified the release build.","next_step":"Publish the verified build.","block_indices":[0]}],"decisions":["Publish verified build."],"blockers":[]}
            """

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                finalResponse: finalResponse),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.hasPrefix("### Tasks"))
        XCTAssertFalse(overview.contains("### At a glance"))
        XCTAssertEqual(occurrences(of: "Updated the signing configuration", in: overview), 1)
        XCTAssertEqual(occurrences(of: "Publish", in: overview), 1)
        XCTAssertTrue(overview.contains("Decision: Publish verified build."))
        XCTAssertFalse(overview.contains("Next —"))
    }

    func testSummaryEvidenceLeadsWithWorkContentBeforeTraceMetadata() {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 9, "Day Digest implementation")],
            screenContexts: [
                context(11, 9, 10, "Implemented task-first digest extraction."),
            ],
            meetings: [],
            calendar: calendar)

        let material = evidence.summaryChunks().joined(separator: "\n")
        let workHeader = material.range(of: "WORK CONTENT")!.lowerBound
        let workText = material.range(of: "Implemented task-first")!.lowerBound
        let metadata = material.range(of: "LOW-PRIORITY TRACE METADATA")!.lowerBound

        XCTAssertLessThan(workHeader, workText)
        XCTAssertLessThan(workText, metadata)
    }

    func testOnlyExactConsecutiveScreenDuplicatesAreCollapsed() {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                ActivityBlock(
                    id: 1, app: "Xcode", title: "Editor",
                    start: time(9), end: time(10)),
            ],
            screenContexts: [
                context(1, 9, 5, "same text"),
                context(2, 9, 6, "same text"),
                context(3, 9, 7, "different text"),
                context(4, 9, 8, "same text"),
            ],
            meetings: [],
            calendar: calendar)

        XCTAssertEqual(evidence.activities.first?.contexts.map(\.snapshotID), [1, 3, 4])
    }

    func testSummaryDropsRecurringAccessibilityChromeButJournalKeepsIt() {
        let chrome = "this button also has an action to zoom the window "
            + "Bookmarks New Tab Back Forward Reload substantive page content"
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 9, "Research")],
            screenContexts: [context(1, 9, 5, chrome, app: "Google Chrome")],
            meetings: [],
            calendar: calendar)

        let summaryMaterial = evidence.summaryChunks().joined(separator: "\n")
        let journal = evidence.renderDocument(summary: "Summary", calendar: calendar)

        XCTAssertFalse(summaryMaterial.localizedCaseInsensitiveContains(
            "this button also has an action to zoom the window"))
        XCTAssertFalse(summaryMaterial.localizedCaseInsensitiveContains(
            "Bookmarks New Tab Back Forward Reload"))
        XCTAssertTrue(summaryMaterial.contains("substantive page content"))
        XCTAssertTrue(journal.contains("this button also has an action to zoom the window"))
        XCTAssertTrue(journal.contains("Bookmarks New Tab Back Forward Reload"))
    }

    func testSummaryOmitsLoginWindowButJournalKeepsIt() {
        let login = ActivityBlock(
            id: 1,
            app: "loginwindow",
            title: "Login Window",
            start: time(8),
            end: time(8, 2))
        let work = ActivityBlock(
            id: 2,
            app: "Xcode",
            title: "DayDigestEvidence.swift",
            start: time(9),
            end: time(9, 45))
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [login, work],
            screenContexts: [],
            meetings: [],
            calendar: calendar)

        let summaryMaterial = evidence.summaryChunks().joined(separator: "\n")
        let journal = evidence.renderDocument(summary: "Summary", calendar: calendar)

        XCTAssertFalse(summaryMaterial.localizedCaseInsensitiveContains("loginwindow"))
        XCTAssertTrue(summaryMaterial.contains("DayDigestEvidence.swift"))
        XCTAssertTrue(journal.localizedCaseInsensitiveContains("loginwindow"))
    }

    func testFreshnessOnlyMarksDigestWhenEvidenceIsNewer() {
        let digest = time(18)
        XCTAssertFalse(DayDigestFreshness.isStale(
            digestModifiedAt: digest,
            latestEvidenceAt: time(17, 59)))
        XCTAssertFalse(DayDigestFreshness.isStale(
            digestModifiedAt: digest,
            latestEvidenceAt: digest))
        XCTAssertTrue(DayDigestFreshness.isStale(
            digestModifiedAt: digest,
            latestEvidenceAt: time(21)))
        XCTAssertFalse(DayDigestFreshness.isStale(
            digestModifiedAt: nil,
            latestEvidenceAt: time(21)))
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
