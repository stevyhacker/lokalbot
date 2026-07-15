import XCTest
@testable import LokalBot

/// Structured-outcomes extraction: the tolerant parse of the model's reply,
/// the schema fed to grammar-constrained backends, the on-disk round trip,
/// the chat observation formatter, and the `get_action_items` tool against a
/// planted library.
@MainActor
final class MeetingOutcomesTests: XCTestCase {

    // MARK: - Parsing

    func testParseCleanJSON() throws {
        let outcomes = try XCTUnwrap(OutcomesExtractor.parse("""
            {"action_items": [{"text": "Benchmark failover", "owner": "Ana", "due": "Friday", "for_user": false}],
             "decisions": ["Adopt Redis"],
             "open_questions": ["Who owns the migration?"]}
            """))
        XCTAssertEqual(outcomes.actionItems,
                       [.init(text: "Benchmark failover", owner: "Ana", due: "Friday")])
        XCTAssertEqual(outcomes.decisions, ["Adopt Redis"])
        XCTAssertEqual(outcomes.openQuestions, ["Who owns the migration?"])
    }

    func testParseToleratesReasoningFencesAndProse() throws {
        let raw = """
            <think>Let me look for tasks.</think>Here are the outcomes:
            ```json
            {"action_items": [{"text": "Ship the fix", "owner": "", "due": ""}],
             "decisions": [], "open_questions": []}
            ```
            """
        let outcomes = try XCTUnwrap(OutcomesExtractor.parse(raw))
        XCTAssertEqual(outcomes.actionItems.count, 1)
        XCTAssertEqual(outcomes.actionItems.first?.text, "Ship the fix")
        // Empty owner/due (the schema's "not stated" convention) collapse to nil.
        XCTAssertNil(outcomes.actionItems.first?.owner)
        XCTAssertNil(outcomes.actionItems.first?.due)
        XCTAssertTrue(outcomes.decisions.isEmpty)
    }

    func testParseSkipsMalformedEntriesAndBlankStrings() throws {
        let outcomes = try XCTUnwrap(OutcomesExtractor.parse("""
            {"action_items": [{"owner": "Ana"}, {"text": "  "}, {"text": "Real task"}],
             "decisions": ["", "  ", "Keep it"], "open_questions": []}
            """))
        XCTAssertEqual(outcomes.actionItems.map(\.text), ["Real task"])
        XCTAssertEqual(outcomes.decisions, ["Keep it"])
    }

    func testParseGarbageReturnsNil() {
        XCTAssertNil(OutcomesExtractor.parse("No outcomes worth mentioning."))
        XCTAssertNil(OutcomesExtractor.parse(""))
    }

    func testEmptyArraysParseAsEmptyOutcomes() throws {
        let outcomes = try XCTUnwrap(OutcomesExtractor.parse(
            #"{"action_items": [], "decisions": [], "open_questions": []}"#))
        XCTAssertTrue(outcomes.isEmpty)
    }

    func testParseMarksNormalizesAndPrioritizesActionsForTheUser() throws {
        let outcomes = try XCTUnwrap(OutcomesExtractor.parse("""
            {"action_items": [
                {"text": "Review the rollout", "owner": "Ana", "due": "", "for_user": false},
                {"text": "Send the draft", "owner": "Stevan", "due": "Friday", "for_user": true},
                {"text": "Book the room", "owner": "Stevan", "due": "", "for_user": false}
             ], "decisions": [], "open_questions": []}
            """, userSpeakerLabel: "Stevan"))

        XCTAssertEqual(outcomes.actionItems.map(\.text),
                       ["Send the draft", "Book the room", "Review the rollout"])
        XCTAssertEqual(outcomes.userActionItems.map(\.owner), ["Me", "Me"])
        XCTAssertEqual(outcomes.otherActionItems.map(\.owner), ["Ana"])
    }

    // MARK: - Schema and prompt

    func testSchemaSerializesAsJSON() throws {
        let data = try JSONSerialization.data(withJSONObject: OutcomesExtractor.schema)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object["required"] as? [String] ?? []),
                       ["action_items", "decisions", "open_questions"])
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        let actionItems = try XCTUnwrap(properties["action_items"] as? [String: Any])
        let item = try XCTUnwrap(actionItems["items"] as? [String: Any])
        XCTAssertEqual(Set(item["required"] as? [String] ?? []),
                       ["text", "owner", "due", "for_user"])
    }

    func testSystemPromptAlwaysChecksWhatTheUserNeedsToDo() {
        let prompt = OutcomesExtractor.systemPrompt(userSpeakerLabel: "Stevan")
        XCTAssertTrue(prompt.contains("everything actionable for that user"), prompt)
        XCTAssertTrue(prompt.contains("commitments made by \"Stevan\""), prompt)
        XCTAssertTrue(prompt.contains("requests or assignments directed to \"Stevan\""), prompt)
        XCTAssertTrue(prompt.contains("\"for_user\" to true"), prompt)
        XCTAssertTrue(prompt.contains("set \"owner\" to \"Me\""), prompt)
    }

    func testPromptPrefersTranscriptUntilItOutgrowsTheContext() {
        let short = OutcomesExtractor.prompt(transcriptMarkdown: "short transcript",
                                             summary: "the summary")
        XCTAssertTrue(short.contains("short transcript"))
        let long = OutcomesExtractor.prompt(
            transcriptMarkdown: String(repeating: "x", count: 25_000), summary: "the summary")
        XCTAssertTrue(long.contains("the summary"))
        XCTAssertFalse(long.contains("xxxxx"))
    }

    func testOnlyShortBuiltInOutcomesCanOverlapSummary() {
        XCTAssertTrue(ProcessingPipeline.shouldExtractOutcomesConcurrently(
            transcriptCharacterCount: OutcomesExtractor.transcriptCharacterLimit,
            backend: .builtIn))
        XCTAssertFalse(ProcessingPipeline.shouldExtractOutcomesConcurrently(
            transcriptCharacterCount: OutcomesExtractor.transcriptCharacterLimit + 1,
            backend: .builtIn))
        XCTAssertFalse(ProcessingPipeline.shouldExtractOutcomesConcurrently(
            transcriptCharacterCount: 1_000,
            backend: .openAICompatible))
    }

    // MARK: - Disk round trip

    func testWriteAndLoadRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-outcomes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        XCTAssertNil(MeetingOutcomes.load(from: folder))
        var outcomes = MeetingOutcomes()
        outcomes.actionItems = [.init(text: "Benchmark failover", owner: "Ana")]
        outcomes.decisions = ["Adopt Redis"]
        try outcomes.write(to: folder)
        XCTAssertEqual(MeetingOutcomes.load(from: folder), outcomes)
    }

    // MARK: - Formatting

    func testFormatOutcomesListsSectionsWithIDs() {
        let meeting = Meeting(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            title: "Caching strategy", appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_800),
            relativePath: "meetings/2026/06/caching")
        var outcomes = MeetingOutcomes()
        outcomes.actionItems = [
            .init(text: "Send the migration plan", owner: "Me", due: "Thursday"),
            .init(text: "Benchmark failover", owner: "Ana", due: "Friday"),
        ]
        outcomes.decisions = ["Adopt Redis"]
        outcomes.openQuestions = ["Who owns the migration?"]

        let text = MeetingChatFormat.outcomes([(meeting, outcomes)])
        XCTAssertTrue(text.contains("[11111111] Caching strategy"), text)
        XCTAssertTrue(text.contains("My action items:\n- Send the migration plan (due: Thursday)"), text)
        XCTAssertTrue(text.contains("Other action items:"), text)
        XCTAssertTrue(text.contains("- Benchmark failover (owner: Ana, due: Friday)"), text)
        XCTAssertTrue(text.contains("Decisions:\n- Adopt Redis"), text)
        XCTAssertTrue(text.contains("Open questions:\n- Who owns the migration?"), text)
    }

    func testFormatEmptyExplainsWhereOutcomesComeFrom() {
        XCTAssertTrue(MeetingChatFormat.outcomes([]).contains("extracted when a meeting is summarized"))
    }

    // MARK: - get_action_items tool (planted library)

    func testGetActionItemsAgainstPlantedLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-outcomes-tool-\(UUID().uuidString)", isDirectory: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            unsetenv("LOKALBOT_STORAGE_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let storage = StorageManager()
        // A recent meeting with outcomes, and an old one whose outcomes should
        // fall outside the default 7-day scan.
        let recent = Meeting(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            title: "Caching strategy", appName: "Zoom",
            startedAt: Date().addingTimeInterval(-3_600),
            endedAt: Date(), relativePath: "meetings/2026/07/caching")
        let old = Meeting(
            id: UUID(uuidString: "22222222-3333-4444-8555-666666666666")!,
            title: "Kickoff", appName: "Meet",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_800),
            relativePath: "meetings/2023/11/kickoff")
        for meeting in [recent, old] {
            let folder = meeting.folderURL(in: storage)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var recentOutcomes = MeetingOutcomes()
        recentOutcomes.actionItems = [.init(text: "Benchmark failover", owner: "Ana")]
        try recentOutcomes.write(to: recent.folderURL(in: storage))
        var oldOutcomes = MeetingOutcomes()
        oldOutcomes.decisions = ["Start the project"]
        try oldOutcomes.write(to: old.folderURL(in: storage))

        let sqlite = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        var settings = AppSettings()
        settings.semanticSearchEnabled = false
        let tools = MeetingChatTools(
            meetings: { [recent, old] }, storage: storage,
            searchIndex: SearchIndex(databaseURL: sqlite),
            embeddingIndex: EmbeddingIndex(databaseURL: sqlite, storage: storage),
            activityStore: ActivityStore(databaseURL: sqlite),
            settings: { settings })

        let recentScan = await tools.run(ChatToolCall(name: "get_action_items", arguments: [:]))
        XCTAssertTrue(recentScan.text.contains("Benchmark failover"), recentScan.text)
        XCTAssertFalse(recentScan.text.contains("Start the project"), recentScan.text)
        XCTAssertEqual(recentScan.summary, "last 7 days — 1 action item")

        let byID = await tools.run(ChatToolCall(
            name: "get_action_items", arguments: ["id": SessionLookup.shortID(old.id)]))
        XCTAssertTrue(byID.text.contains("Start the project"), byID.text)
        XCTAssertEqual(byID.summary, "Kickoff — 0 action items")

        let miss = await tools.run(ChatToolCall(name: "get_action_items",
                                                arguments: ["id": "zzzzzzzz"]))
        XCTAssertTrue(miss.text.contains("No meeting matches"), miss.text)
    }
}
