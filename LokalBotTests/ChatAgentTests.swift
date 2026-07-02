import XCTest
@testable import LokalBot

/// Tests for the in-app meeting chat assistant: the tolerant tool-call protocol,
/// the system-prompt builder, the ReAct loop (driven by a scripted engine and a
/// fake tool runner), the pure observation formatters, and the live tool runner
/// against a planted on-disk library.
@MainActor
final class ChatAgentTests: XCTestCase {

    // MARK: - Protocol parsing

    func testParsePlainToolCall() {
        let action = ChatPrompt.parse(
            #"{"tool":"search_meetings","arguments":{"query":"redis"}}"#,
            tools: ["search_meetings"])
        guard case .call(let call) = action else { return XCTFail("expected a tool call") }
        XCTAssertEqual(call.name, "search_meetings")
        XCTAssertEqual(call.string("query"), "redis")
    }

    func testParseFencedToolCallSurroundedByProse() {
        let text = """
        Sure, let me look that up.
        ```json
        {"tool": "search_meetings", "arguments": {"query": "pricing decision"}}
        ```
        """
        guard case .call(let call) = ChatPrompt.parse(text, tools: ["search_meetings"]) else {
            return XCTFail("expected a tool call extracted from fenced JSON")
        }
        XCTAssertEqual(call.string("query"), "pricing decision")
    }

    func testParseUnknownToolNameIsTreatedAsAnswer() {
        // Shaped like a tool call, but the name isn't registered — never execute it.
        let action = ChatPrompt.parse(#"{"tool":"delete_everything","arguments":{}}"#,
                                      tools: ["search_meetings"])
        guard case .answer = action else { return XCTFail("unknown tool must not be called") }
    }

    func testParsePlainProseIsAnswer() {
        guard case .answer(let text) = ChatPrompt.parse("You have three meetings today.",
                                                        tools: ["search_meetings"]) else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(text, "You have three meetings today.")
    }

    func testParseStripsReasoningBeforeAnswer() {
        guard case .answer(let text) = ChatPrompt.parse("<think>hidden</think>The answer is 42.",
                                                        tools: []) else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(text, "The answer is 42.")
    }

    func testParseCoercesNumericAndFlatArguments() {
        // No "arguments" wrapper, and a numeric value the model didn't quote.
        guard case .call(let call) = ChatPrompt.parse(#"{"tool":"list_meetings","limit":5}"#,
                                                      tools: ["list_meetings"]) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertEqual(call.int("limit"), 5)
    }

    func testExtractJSONObjectSkipsBracesInsideStrings() {
        let text = #"prefix {"tool":"x","arguments":{"query":"a {weird} value"}} suffix"#
        XCTAssertEqual(ChatPrompt.extractJSONObject(text),
                       #"{"tool":"x","arguments":{"query":"a {weird} value"}}"#)
    }

    func testToolCallJSONRoundTrips() {
        let call = ChatToolCall(name: "get_meeting", arguments: ["id": "abc12345", "include": "summary"])
        guard case .call(let reparsed) = ChatPrompt.parse(call.json, tools: ["get_meeting"]) else {
            return XCTFail("re-parsing canonical JSON should yield a tool call")
        }
        XCTAssertEqual(reparsed.name, "get_meeting")
        XCTAssertEqual(reparsed.string("id"), "abc12345")
        XCTAssertEqual(reparsed.string("include"), "summary")
    }

    func testFinalTextFallsBackWhenStillAToolCall() {
        XCTAssertEqual(ChatPrompt.finalText(#"{"tool":"search_meetings","arguments":{}}"#),
                       ChatPrompt.fallbackAnswer)
        XCTAssertEqual(ChatPrompt.finalText("Here is the summary."), "Here is the summary.")
    }

    func testParseNativeFunctionCallWithTokens() {
        // Some Qwen-compatible local models emit this form instead of JSON.
        let text = "<|tool_call_start|>[get_meeting(id='abc12345', include='summary')]<|tool_call_end|>"
        guard case .call(let call) = ChatPrompt.parse(text, tools: ["get_meeting"]) else {
            return XCTFail("native function-call form should parse as a tool call")
        }
        XCTAssertEqual(call.name, "get_meeting")
        XCTAssertEqual(call.string("id"), "abc12345")
        XCTAssertEqual(call.string("include"), "summary")
    }

    func testParseNativeCallNumericAndDoubleQuotes() {
        guard case .call(let call) = ChatPrompt.parse(#"list_meetings(query="sync", limit=3)"#,
                                                      tools: ["list_meetings"]) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertEqual(call.string("query"), "sync")
        XCTAssertEqual(call.int("limit"), 3)
    }

    func testStripToolTokensLeavesPlainAnswer() {
        let text = "<|tool_call_start|>Here is your answer.<|tool_call_end|>"
        guard case .answer(let answer) = ChatPrompt.parse(text, tools: ["get_meeting"]) else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(answer, "Here is your answer.")
    }

    // MARK: - System prompt

    func testSystemPromptListsToolsAndLibrary() {
        let prompt = ChatPrompt.systemPrompt(
            tools: [ChatToolSpec(name: "search_meetings", summary: "Find spoken content.",
                                 arguments: [.init(name: "query", description: "What to find.", required: true)])],
            libraryOverview: "The user has 2 recorded meetings.")
        XCTAssertTrue(prompt.contains("search_meetings"))
        XCTAssertTrue(prompt.contains("Find spoken content."))
        XCTAssertTrue(prompt.contains("The user has 2 recorded meetings."))
        XCTAssertTrue(prompt.contains("JSON"))
    }

    // MARK: - Agent loop

    func testAgentRunsToolThenAnswers() async throws {
        let engine = ScriptedEngine([
            #"{"tool": "search_meetings", "arguments": {"query": "redis"}}"#,
            "We decided to adopt Redis for caching.",
        ])
        let runner = FakeRunner(
            specs: [ChatToolSpec(name: "search_meetings", summary: "search",
                                 arguments: [.init(name: "query", description: "q", required: true)])],
            overview: "1 meeting",
            results: ["search_meetings": ChatToolResult(text: "Hit: adopt Redis", summary: "1 match")])
        let agent = ChatAgent(engine: engine, runner: runner)

        var events: [String] = []
        let answer = try await agent.respond(history: [], latest: "what did we decide?") { event in
            switch event {
            case .toolStarted(let call): events.append("start:\(call.name)")
            case .toolFinished(let name, _): events.append("finish:\(name)")
            }
        }

        XCTAssertEqual(answer, "We decided to adopt Redis for caching.")
        XCTAssertEqual(runner.calls.map(\.name), ["search_meetings"])
        XCTAssertEqual(runner.calls.first?.string("query"), "redis")
        XCTAssertEqual(events, ["start:search_meetings", "finish:search_meetings"])
        // The observation must have been fed back into the second generate call.
        XCTAssertTrue(engine.prompts.last?.context.contains { $0.contains("Observation: Hit: adopt Redis") } ?? false)
    }

    func testAgentAnswersDirectlyWithoutTools() async throws {
        let engine = ScriptedEngine(["You have no meetings recorded yet."])
        let runner = FakeRunner(specs: [], overview: "no meetings", results: [:])
        let agent = ChatAgent(engine: engine, runner: runner)
        let answer = try await agent.respond(history: [], latest: "anything?") { _ in }
        XCTAssertEqual(answer, "You have no meetings recorded yet.")
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testAgentForcesAnswerAfterMaxSteps() async throws {
        let loopingCall = #"{"tool":"search_meetings","arguments":{"query":"x"}}"#
        let engine = ScriptedEngine(Array(repeating: loopingCall, count: 8))
        let runner = FakeRunner(
            specs: [ChatToolSpec(name: "search_meetings", summary: "search", arguments: [])],
            overview: "",
            results: ["search_meetings": ChatToolResult(text: "no matches", summary: "0")])
        var agent = ChatAgent(engine: engine, runner: runner)
        agent.maxSteps = 2

        let answer = try await agent.respond(history: [], latest: "find x") { _ in }
        // 2 in-loop tool calls, then a forced pass that still loops → fallback.
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(answer, ChatPrompt.fallbackAnswer)
    }

    // MARK: - Pure formatters

    func testLibraryOverviewEmptyAndPopulated() {
        XCTAssertEqual(MeetingChatFormat.libraryOverview([], limit: 5),
                       "The user has no recorded meetings yet.")
        let text = MeetingChatFormat.libraryOverview([sampleMeeting(title: "Kickoff")], limit: 5)
        XCTAssertTrue(text.contains("1 recorded meeting"))
        XCTAssertTrue(text.contains("Kickoff"))
    }

    func testListFormatsMeetingRows() {
        let meeting = sampleMeeting(title: "Weekly sync")
        let text = MeetingChatFormat.list([meeting])
        XCTAssertTrue(text.contains("Weekly sync"))
        XCTAssertTrue(text.contains(SessionLookup.shortID(meeting.id)))
    }

    func testSearchResultsEmptyAndKeyword() {
        XCTAssertEqual(
            MeetingChatFormat.searchResults(query: "ghost", keyword: [], semantic: [], meetings: []),
            "No matches for “ghost”.")

        let meeting = sampleMeeting(title: "Budget review")
        let hit = SearchIndex.Hit(meetingID: meeting.id, kind: .segment, start: 90,
                                  snippet: "we cut the «budget» by 10%", speaker: "me")
        let text = MeetingChatFormat.searchResults(query: "budget", keyword: [hit],
                                                   semantic: [], meetings: [meeting])
        XCTAssertTrue(text.contains("Budget review"))
        XCTAssertTrue(text.contains("00:01:30"))      // timestamp from start=90
        XCTAssertFalse(text.contains("«"))            // FTS markers stripped
    }

    func testMeetingIncludeSelectsSections() {
        let meeting = sampleMeeting(title: "Retro")
        let summaryOnly = MeetingChatFormat.meeting(meeting, summary: "S", transcript: "T", include: "summary")
        XCTAssertTrue(summaryOnly.contains("## Summary"))
        XCTAssertFalse(summaryOnly.contains("## Transcript"))

        let transcriptOnly = MeetingChatFormat.meeting(meeting, summary: "S", transcript: "T", include: "transcript")
        XCTAssertTrue(transcriptOnly.contains("## Transcript"))
        XCTAssertFalse(transcriptOnly.contains("## Summary"))

        let all = MeetingChatFormat.meeting(meeting, summary: "S", transcript: "T", include: "all")
        XCTAssertTrue(all.contains("## Summary"))
        XCTAssertTrue(all.contains("## Transcript"))
    }

    func testCleanStripsMarkersAndCollapsesWhitespace() {
        XCTAssertEqual(MeetingChatFormat.clean("a «hit»\n   b"), "a hit b")
    }

    // MARK: - Live tool runner (planted library)

    func testToolsListSearchAndGetAgainstPlantedLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-chat-\(UUID().uuidString)", isDirectory: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            unsetenv("LOKALBOT_STORAGE_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let storage = StorageManager()      // rooted at our temp dir via the env hook
        let meeting = Meeting(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            title: "Caching strategy", appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_800),
            relativePath: "meetings/2026/06/caching", hasSystemTrack: true)
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let transcript = Transcript(segments: [
            .init(start: 12, end: 18, speaker: "me",
                  text: "Let's adopt Redis for the eviction policy.", confidence: nil),
            .init(start: 20, end: 25, speaker: "them",
                  text: "Agreed, benchmark failover latency first.", confidence: nil),
        ], engine: "test")
        try JSONEncoder().encode(transcript)
            .write(to: folder.appendingPathComponent("transcript.json"))
        try Data(transcript.markdown.utf8)
            .write(to: folder.appendingPathComponent("transcript.md"))
        try Data("## TL;DR\nAdopt Redis.\n## Action items\n- Benchmark failover".utf8)
            .write(to: folder.appendingPathComponent("summary.md"))

        let sqlite = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        let searchIndex = SearchIndex(databaseURL: sqlite)
        searchIndex.reindex(meeting, storage: storage)
        let embeddingIndex = EmbeddingIndex(databaseURL: sqlite, storage: storage)
        let activityStore = ActivityStore(databaseURL: sqlite)

        var settings = AppSettings()
        settings.semanticSearchEnabled = false      // keep the test offline (no embed server)

        let tools = MeetingChatTools(
            meetings: { [meeting] }, storage: storage,
            searchIndex: searchIndex, embeddingIndex: embeddingIndex,
            activityStore: activityStore,
            settings: { settings })

        let list = await tools.run(ChatToolCall(name: "list_meetings", arguments: [:]))
        XCTAssertTrue(list.text.contains("Caching strategy"), "list: \(list.text)")

        let search = await tools.run(ChatToolCall(name: "search_meetings",
                                                  arguments: ["query": "eviction"]))
        XCTAssertTrue(search.text.contains("Caching strategy"), "search: \(search.text)")
        XCTAssertTrue(search.text.lowercased().contains("eviction"), "search: \(search.text)")

        let summary = await tools.run(ChatToolCall(name: "get_meeting",
                                                   arguments: ["id": SessionLookup.shortID(meeting.id)]))
        XCTAssertTrue(summary.text.contains("Adopt Redis"), "get: \(summary.text)")
        XCTAssertTrue(summary.text.contains("## Summary"))

        let latestTranscript = await tools.run(ChatToolCall(name: "get_meeting",
                                                            arguments: ["id": "latest", "include": "transcript"]))
        XCTAssertTrue(latestTranscript.text.contains("Redis"), "get transcript: \(latestTranscript.text)")

        let miss = await tools.run(ChatToolCall(name: "get_meeting", arguments: ["id": "zzzzzzzz"]))
        XCTAssertTrue(miss.text.contains("No meeting matches"), "miss: \(miss.text)")
    }

    // MARK: - Screen / activity tools

    func testSearchScreenAndActivitySummaryAgainstPlantedStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-screen-\(UUID().uuidString)", isDirectory: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            unsetenv("LOKALBOT_STORAGE_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let storage = StorageManager()
        let sqlite = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        try FileManager.default.createDirectory(at: storage.rootURL, withIntermediateDirectories: true)
        let activityStore = ActivityStore(databaseURL: sqlite)

        activityStore.insertScreenshot(
            ts: Date(), path: "/tmp/x.heic.enc", app: "Safari",
            windowTitle: "Stripe invoicing docs", trigger: "app_switch",
            ocr: "How to issue a refund for an invoice in the Stripe dashboard")
        activityStore.insert(ActivityBlock(app: "Xcode", title: "LokalBot.xcodeproj",
                                           start: Date().addingTimeInterval(-7_200),
                                           end: Date().addingTimeInterval(-3_600)))
        activityStore.insert(ActivityBlock(app: "Safari", title: "Stripe invoicing docs",
                                           start: Date().addingTimeInterval(-3_600),
                                           end: Date().addingTimeInterval(-3_000)))

        var settings = AppSettings()
        settings.semanticSearchEnabled = false
        let tools = MeetingChatTools(
            meetings: { [] }, storage: storage,
            searchIndex: SearchIndex(databaseURL: sqlite),
            embeddingIndex: EmbeddingIndex(databaseURL: sqlite, storage: storage),
            activityStore: activityStore,
            settings: { settings })

        let hit = await tools.run(ChatToolCall(name: "search_screen",
                                               arguments: ["query": "refund invoice"]))
        XCTAssertTrue(hit.text.contains("Safari"), "screen: \(hit.text)")
        XCTAssertTrue(hit.text.contains("Stripe invoicing docs"), "screen: \(hit.text)")

        // Natural-language question rescued by the relaxed OR fallback.
        let rescued = await tools.run(ChatToolCall(name: "search_screen",
                                                   arguments: ["query": "how do I refund that invoice"]))
        XCTAssertFalse(rescued.text.contains("No screen-text matches"), "rescued: \(rescued.text)")

        let miss = await tools.run(ChatToolCall(name: "search_screen",
                                                arguments: ["query": "kubernetes"]))
        XCTAssertTrue(miss.text.contains("No screen-text matches"), "miss: \(miss.text)")

        let summary = await tools.run(ChatToolCall(name: "activity_summary", arguments: [:]))
        XCTAssertTrue(summary.text.contains("Xcode: 1h 00m"), "summary: \(summary.text)")
        XCTAssertTrue(summary.text.contains("Safari: 10m"), "summary: \(summary.text)")
        XCTAssertTrue(summary.text.contains("LokalBot.xcodeproj"), "summary: \(summary.text)")

        let empty = await tools.run(ChatToolCall(name: "activity_summary",
                                                 arguments: ["day": "2020-01-01"]))
        XCTAssertTrue(empty.text.contains("No app activity tracked"), "empty: \(empty.text)")

        let bad = await tools.run(ChatToolCall(name: "activity_summary",
                                               arguments: ["day": "next tuesday"]))
        XCTAssertTrue(bad.text.contains("Could not understand day"), "bad: \(bad.text)")
    }

    func testParseDayHandlesRelativeAndISOForms() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(MeetingChatTools.parseDay("today", now: now), now)
        let yesterday = MeetingChatTools.parseDay("yesterday", now: now)
        XCTAssertEqual(yesterday.map { Calendar.current.dateComponents([.day], from: $0, to: now).day }, 1)
        XCTAssertNotNil(MeetingChatTools.parseDay("2026-07-01"))
        XCTAssertNil(MeetingChatTools.parseDay("garbage"))
    }

    func testActivitySummaryFormatterAggregatesAndListsMeetings() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let blocks = [
            ActivityBlock(app: "Xcode", title: "foo.swift", start: base, end: base.addingTimeInterval(1_800)),
            ActivityBlock(app: "Xcode", title: "bar.swift", start: base, end: base.addingTimeInterval(5_400)),
            ActivityBlock(app: "Slack", title: "#general", start: base, end: base.addingTimeInterval(600)),
        ]
        let text = MeetingChatFormat.activitySummary(
            dayLabel: "Jul 1, 2026", blocks: blocks, meetings: [sampleMeeting(title: "Standup")])
        XCTAssertTrue(text.contains("Xcode: 2h 00m"), text)
        XCTAssertTrue(text.contains("Slack: 10m"), text)
        XCTAssertTrue(text.contains("Standup"), text)
        // Longest-title-first within an app.
        XCTAssertTrue(text.range(of: "bar.swift")!.lowerBound
                      < text.range(of: "foo.swift")!.lowerBound, text)
    }

    func testDurationLabelFormats() {
        XCTAssertEqual(MeetingChatFormat.durationLabel(45), "45s")
        XCTAssertEqual(MeetingChatFormat.durationLabel(600), "10m")
        XCTAssertEqual(MeetingChatFormat.durationLabel(7_500), "2h 05m")
    }

    // MARK: - FTS query relaxation

    func testFtsQueryStrictAndsTermsButRelaxesOnRequest() {
        // Default: quote + AND every term, prefix-match the last (search-as-you-type).
        XCTAssertEqual(SearchIndex.ftsQuery(from: "what did we decide about caching"),
                       #""what" "did" "we" "decide" "about" "caching" *"#)
        // Relaxed: drop stop words, OR the content terms for recall.
        XCTAssertEqual(
            SearchIndex.ftsQuery(from: "what did we decide about caching",
                                 matchAll: false, dropStopWords: true),
            #""decide" OR "caching""#)
        // All terms are stop words → keep them rather than emit an empty query.
        XCTAssertEqual(
            SearchIndex.ftsQuery(from: "what did we", matchAll: false, dropStopWords: true),
            #""what" OR "did" OR "we""#)
        XCTAssertNil(SearchIndex.ftsQuery(from: "   "))
    }

    func testSearchRescuesNaturalLanguageQuery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-nlsearch-\(UUID().uuidString)", isDirectory: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            unsetenv("LOKALBOT_STORAGE_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let storage = StorageManager()
        let meeting = Meeting(
            id: UUID(uuidString: "22222222-3333-4444-8555-666666666666")!,
            title: "Caching strategy", appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_800),
            relativePath: "meetings/2026/06/nlsearch", hasSystemTrack: true)
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = Transcript(segments: [
            .init(start: 10, end: 16, speaker: "me",
                  text: "We will use Redis for caching going forward.", confidence: nil),
        ], engine: "test")
        try JSONEncoder().encode(transcript)
            .write(to: folder.appendingPathComponent("transcript.json"))

        let sqlite = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        let searchIndex = SearchIndex(databaseURL: sqlite)
        searchIndex.reindex(meeting, storage: storage)
        let embeddingIndex = EmbeddingIndex(databaseURL: sqlite, storage: storage)
        let activityStore = ActivityStore(databaseURL: sqlite)

        var settings = AppSettings()
        settings.semanticSearchEnabled = false      // no embed server in tests

        let tools = MeetingChatTools(
            meetings: { [meeting] }, storage: storage,
            searchIndex: searchIndex, embeddingIndex: embeddingIndex,
            activityStore: activityStore,
            settings: { settings })

        // Strict FTS ANDs every stop word and finds nothing on the raw question…
        XCTAssertTrue(searchIndex.search("what did we decide about caching").isEmpty)
        // …but the chat tool's keyword fallback rescues the content terms.
        let search = await tools.run(ChatToolCall(name: "search_meetings",
                                                  arguments: ["query": "what did we decide about caching"]))
        XCTAssertFalse(search.text.contains("No matches"), "search: \(search.text)")
        XCTAssertTrue(search.text.contains("Caching strategy"), "search: \(search.text)")
    }

    // MARK: - Helpers

    private func sampleMeeting(title: String) -> Meeting {
        Meeting(id: UUID(), title: title, appName: "Zoom",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: Date(timeIntervalSince1970: 1_700_001_800),
                relativePath: "meetings/sample", hasSystemTrack: false)
    }
}

// MARK: - Test doubles

/// A `TextEngine` that returns canned outputs in order and records every call,
/// so the agent loop can be exercised deterministically with no model.
private final class ScriptedEngine: TextEngine {
    private var outputs: [String]
    private(set) var prompts: [(system: String, prompt: String, context: [String])] = []

    init(_ outputs: [String]) { self.outputs = outputs }

    var displayName: String { "Scripted" }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        prompts.append((system, prompt, context))
        return outputs.isEmpty ? "" : outputs.removeFirst()
    }
}

@MainActor
private final class FakeRunner: ChatToolRunner {
    let specs: [ChatToolSpec]
    private let overview: String
    private let results: [String: ChatToolResult]
    private(set) var calls: [ChatToolCall] = []

    init(specs: [ChatToolSpec], overview: String, results: [String: ChatToolResult]) {
        self.specs = specs
        self.overview = overview
        self.results = results
    }

    func libraryOverview() -> String { overview }

    func run(_ call: ChatToolCall) async -> ChatToolResult {
        calls.append(call)
        return results[call.name] ?? ChatToolResult(text: "no result", summary: "none")
    }
}
