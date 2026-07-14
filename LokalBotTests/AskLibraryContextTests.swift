import XCTest
@testable import LokalBot

final class AskLibraryContextTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askcontext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)

        try MeetingFixture.write([
            .init(
                id: UUID(uuidString: "AAAAAAAA-1111-4222-8333-444444444444")!,
                title: "Cache planning",
                startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                summary: "We chose Redis for the caching layer.",
                transcriptLines: [
                    "Let us decide on caching today.",
                    "Redis wins because of pub sub.",
                ]),
            .init(
                id: UUID(uuidString: "BBBBBBBB-1111-4222-8333-444444444444")!,
                title: "Standup",
                startedAt: Date(timeIntervalSince1970: 1_770_000_000),
                summary: "Daily status.",
                transcriptLines: ["Shipping the caching benchmark tomorrow."]),
        ], under: root)
    }

    override func tearDown() {
        unsetenv("LOKALBOT_STORAGE_ROOT")
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testSearchTermsDropStopwordsAndShortWords() {
        XCTAssertEqual(
            AskLibraryContext.searchTerms(from: "What did we decide about caching?"),
            ["decide", "caching"])
        XCTAssertEqual(AskLibraryContext.searchTerms(from: "Tell me about it"), [])
        XCTAssertEqual(
            AskLibraryContext.searchTerms(from: "Caching CACHING caching"),
            ["caching"])
    }

    func testBuildGathersSnippetsForContentTerms() throws {
        let meetings = try SessionLookup.loadAllMeetings()
        let bundle = AskLibraryContext.build(
            question: "What did we decide about caching?",
            meetings: meetings)
        XCTAssertTrue(bundle.contextText.contains("## Snippets"))
        XCTAssertTrue(bundle.contextText.contains("Redis"))
        XCTAssertTrue(bundle.contextText.contains("- [transcript @00:00:00] Cache planning:"))
    }

    func testBuildInlinesFullSummaryWhenQuestionNamesMeeting() throws {
        let meetings = try SessionLookup.loadAllMeetings()
        let bundle = AskLibraryContext.build(
            question: "Summarize the Cache planning meeting",
            meetings: meetings)
        XCTAssertTrue(bundle.contextText.contains(
            "## Cache planning — 2026-05-28 — full summary"))
        XCTAssertTrue(bundle.contextText.contains("We chose Redis for the caching layer."))
        XCTAssertEqual(bundle.citations.first?.title, "Cache planning")
    }

    func testCitationsNewestFirstWithDayDates() throws {
        let meetings = try SessionLookup.loadAllMeetings()
        let bundle = AskLibraryContext.build(question: "caching", meetings: meetings)
        XCTAssertEqual(bundle.citations.map(\.title), ["Cache planning", "Standup"])
        XCTAssertTrue(bundle.citations.allSatisfy { $0.date.hasPrefix("2026-") })
        XCTAssertEqual(bundle.citations.first?.meeting_id, "aaaaaaaa")
    }

    func testSnippetCapAtTwelve() throws {
        try MeetingFixture.write([
            .init(
                id: UUID(),
                title: "Zephyr readout",
                startedAt: Date(timeIntervalSince1970: 1_781_000_000),
                transcriptLines: (0..<20).map {
                    "zephyr milestone number \($0) update"
                }),
        ], under: root)
        let meetings = try SessionLookup.loadAllMeetings()
        let bundle = AskLibraryContext.build(
            question: "zephyr milestone",
            meetings: meetings)
        let lines = bundle.contextText.split(separator: "\n")
            .filter { $0.hasPrefix("- [") }
        XCTAssertEqual(lines.count, AskLibraryContext.maxSnippets)
    }

    func testSnippetsDedupeAcrossTerms() throws {
        let meetings = try SessionLookup.loadAllMeetings()
        let bundle = AskLibraryContext.build(
            question: "redis caching",
            meetings: meetings)
        let summaryLines = bundle.contextText.split(separator: "\n")
            .filter { $0.hasPrefix("- [summary] Cache planning:") }
        XCTAssertEqual(summaryLines.count, 1)
    }

    func testTitleSummaryMatchesAreRankedCappedAndBudgeted() throws {
        try MeetingFixture.write((0..<10).map { index in
            .init(
                title: "Portfolio review",
                startedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)),
                summary: "rank-\(index)\n" + String(
                    repeating: "🧠",
                    count: AskLibraryContext.maxSummaryUTF8Bytes),
                transcriptLines: [])
        }, under: root)

        let meetings = try SessionLookup.loadAllMeetings()
        let bundle = AskLibraryContext.build(
            question: "Please summarize the Portfolio review meeting",
            meetings: meetings)

        XCTAssertLessThanOrEqual(
            bundle.contextText.utf8.count,
            AskLibraryContext.maxContextUTF8Bytes)
        XCTAssertEqual(
            bundle.contextText.components(separatedBy: "— full summary").count - 1,
            AskLibraryContext.maxTitleSummaryMatches)
        XCTAssertTrue(bundle.contextText.contains("[… summary truncated …]"))
        for index in 6..<10 {
            XCTAssertTrue(bundle.contextText.contains("rank-\(index)"), "missing newest rank \(index)")
        }
        for index in 0..<6 {
            XCTAssertFalse(bundle.contextText.contains("rank-\(index)"), "included older rank \(index)")
        }
    }

    func testEmptyBundleWhenNothingMatches() throws {
        let meetings = try SessionLookup.loadAllMeetings()
        let bundle = AskLibraryContext.build(
            question: "quantum blockchain synergy",
            meetings: meetings)
        XCTAssertEqual(
            bundle,
            AskLibraryContext.ContextBundle(contextText: "", citations: []))
    }

    func testMessagesShape() {
        let messages = AskLibraryContext.messages(question: "Q?", contextText: "CTX")
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertTrue(messages[0]["content"]!.contains("ONLY the meeting context"))
        XCTAssertTrue(messages[0]["content"]!.contains("I couldn't find that in your meetings."))
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertTrue(messages[1]["content"]!.contains("CTX"))
        XCTAssertTrue(messages[1]["content"]!.hasSuffix("Question: Q?"))
    }
}
