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
            return calls.filter(\.isFocus).count
        }
    }

    private struct StructuredDigestEngine: TextEngine {
        let recorder: GenerationRecorder
        var invalidFirstFocus = false
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
                if invalidFirstFocus && index == 1 { return "not valid JSON" }
                return """
                    {"topic":"Segment \(index)","summary":"Grounded work for segment \(index).","source_ids":[]}
                    """
            }
            return """
                {"at_a_glance":[{"block_index":0,"text":"Morning implementation was recorded."},{"block_index":1,"text":"The brief invoice payment was recorded."},{"block_index":2,"text":"Evening verification was recorded."}],"decisions_and_next_steps":[]}
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

    func testSummaryProminenceIsProportionalToRecordedDuration() async throws {
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

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.activeDuration), [5 * 60 * 60, 5 * 60])
        XCTAssertEqual(segments[0].shareOfRecordedTime, 300.0 / 305.0, accuracy: 0.001)
        XCTAssertEqual(segments[1].shareOfRecordedTime, 5.0 / 305.0, accuracy: 0.001)
        XCTAssertEqual(segments.map(\.isPrimary), [true, false])

        let recorder = GenerationRecorder()
        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(recorder: recorder),
            customPrompt: "",
            calendar: calendar)
        let document = evidence.renderDocument(summary: overview, calendar: calendar)
        let presentation = DayDigestPresentation(markdown: document)

        XCTAssertEqual(presentation.focusBlocks.map(\.title), ["Segment 1"])
        XCTAssertEqual(presentation.otherActivityBlocks.map(\.title), ["Segment 2"])
        XCTAssertTrue(presentation.atAGlanceMarkdown.contains("Morning implementation"))
        XCTAssertFalse(presentation.atAGlanceMarkdown.contains("invoice"))
        XCTAssertTrue(document.contains("Invoice payment"))
    }

    func testPrimarySegmentsNeedToCoverOnlyHalfOfRecordedTime() {
        let briefBlocks = (0..<7).map { index in
            block(
                Int64(index + 2),
                startHour: 10 + index,
                endHour: 10 + index,
                endMinute: 5,
                title: "Brief task \(index + 1)",
                app: "Safari")
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
        XCTAssertEqual(segments.filter(\.isPrimary).count, 1)
        XCTAssertEqual(segments.first?.activeDuration, 40 * 60)
        XCTAssertEqual(segments.first?.shareOfRecordedTime ?? 0, 40.0 / 75.0,
                       accuracy: 0.001)
    }

    func testLongActivityReceivesBroaderScreenCoverageThanBriefActivity() {
        let longContexts = (0..<10).map { index in
            context(
                Int64(100 + index),
                9 + index / 2,
                (index % 2) * 30,
                "main project evidence \(index)")
        }
        let briefContexts = (0..<5).map { index in
            context(
                Int64(200 + index),
                16,
                index,
                "invoice evidence \(index)",
                app: "Safari")
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

    func testOverviewGeneratorPreservesEverySegmentAndUsesTaskSpecificReasoning() async throws {
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

        XCTAssertTrue(overview.contains("**08:00–08:45 · Segment 1**"))
        XCTAssertTrue(overview.contains("**13:00–13:45 · Segment 2**"))
        XCTAssertTrue(overview.contains("**19:00–19:45 · Segment 3**"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls.prefix(3).allSatisfy {
            $0.isFocus && $0.maxTokens == 768
                && $0.reasoningBudgetTokens == 256 && $0.temperature == 0.2
        })
        XCTAssertEqual(calls.last, GenerationRecorder.Call(
            isFocus: false,
            maxTokens: 1_200,
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
                invalidFirstFocus: true),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("Segment 2"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[1], GenerationRecorder.Call(
            isFocus: true,
            maxTokens: 1_200,
            reasoningBudgetTokens: 256,
            temperature: 0))
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
