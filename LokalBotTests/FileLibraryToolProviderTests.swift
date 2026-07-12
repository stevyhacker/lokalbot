import XCTest
@testable import LokalBot

final class FileLibraryToolProviderTests: XCTestCase {
    private var root: URL!
    private var gate: AgentAccessGate!
    private var askedQuestions: [String] = []

    private var provider: FileLibraryToolProvider {
        FileLibraryToolProvider(gate: gate) { question in
            self.askedQuestions.append(question)
            return .text("stub answer")
        }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolprovider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        gate = AgentAccessGate(root: root)
        try gate.enable()
        askedQuestions = []

        try MeetingFixture.write([
            .init(
                id: UUID(uuidString: "AAAAAAAA-1111-4222-8333-444444444444")!,
                title: "Cache planning",
                startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                summary: "## TL;DR\nWe chose Redis for the caching layer.",
                transcriptLines: ["Let us decide on caching.", "Redis it is."]),
            .init(
                id: UUID(uuidString: "AAAAAAAB-2222-4333-8444-555555555555")!,
                title: "Old sync",
                startedAt: Date(timeIntervalSince1970: 1_770_000_000),
                summary: "## TL;DR\nAncient history.",
                transcriptLines: ["Nothing to see."]),
        ], under: root)
    }

    override func tearDown() {
        unsetenv("LOKALBOT_STORAGE_ROOT")
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testAdvertisesExactlyTheFourTools() {
        XCTAssertEqual(
            provider.tools.map(\.name),
            ["list_meetings", "get_meeting", "search_meetings", "ask_library"])
        for tool in provider.tools {
            XCTAssertFalse(tool.description.isEmpty, tool.name)
        }
    }

    func testEveryToolRefusedWhenGateDisabled() async {
        gate.disable()
        for name in ["list_meetings", "get_meeting", "search_meetings", "ask_library"] {
            let result = await provider.call(
                name: name,
                arguments: ["id": "latest", "query": "x", "question": "x"])
            XCTAssertTrue(result.isError, name)
            XCTAssertTrue(result.text.hasPrefix("[access_disabled]"), name)
        }
        XCTAssertTrue(askedQuestions.isEmpty)
    }

    func testListMeetingsReturnsBothNewestFirst() async {
        let result = await provider.call(name: "list_meetings", arguments: nil)
        XCTAssertFalse(result.isError)
        guard let cache = result.text.range(of: "Cache planning"),
              let old = result.text.range(of: "Old sync") else {
            return XCTFail("both meetings expected in: \(result.text)")
        }
        XCTAssertLessThan(cache.lowerBound, old.lowerBound)
    }

    func testListMeetingsFiltersByQuerySinceAndLimit() async {
        let byQuery = await provider.call(
            name: "list_meetings",
            arguments: ["query": "cache"])
        XCTAssertTrue(byQuery.text.contains("Cache planning"))
        XCTAssertFalse(byQuery.text.contains("Old sync"))

        let bySince = await provider.call(
            name: "list_meetings",
            arguments: ["since": "2026-04-01"])
        XCTAssertTrue(bySince.text.contains("Cache planning"))
        XCTAssertFalse(bySince.text.contains("Old sync"))

        let badSince = await provider.call(
            name: "list_meetings",
            arguments: ["since": "April 1st"])
        XCTAssertTrue(badSince.isError)
        XCTAssertTrue(badSince.text.hasPrefix("[invalid_arguments]"))

        let capped = await provider.call(
            name: "list_meetings",
            arguments: ["limit": 1])
        XCTAssertTrue(capped.text.contains("Cache planning"))
        XCTAssertFalse(capped.text.contains("Old sync"))
    }

    func testGetMeetingLatestReturnsMarkdownSections() async {
        let result = await provider.call(
            name: "get_meeting",
            arguments: ["id": "latest"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("# Cache planning"))
        XCTAssertTrue(result.text.contains("Redis"))

        let summaryOnly = await provider.call(
            name: "get_meeting",
            arguments: ["id": "latest", "include": "summary"])
        XCTAssertTrue(summaryOnly.text.contains("Redis"))
        XCTAssertFalse(summaryOnly.text.contains("# Cache planning"))
    }

    func testGetMeetingErrorCodes() async {
        let missingID = await provider.call(name: "get_meeting", arguments: nil)
        XCTAssertTrue(missingID.text.hasPrefix("[invalid_arguments]"))

        let notFound = await provider.call(
            name: "get_meeting",
            arguments: ["id": "ffffffff"])
        XCTAssertTrue(notFound.text.hasPrefix("[meeting_not_found]"))

        let ambiguous = await provider.call(
            name: "get_meeting",
            arguments: ["id": "aaaaaaa"])
        XCTAssertTrue(ambiguous.text.hasPrefix("[ambiguous_id]"))
    }

    func testSearchMeetingsReturnsHitJSON() async {
        let result = await provider.call(
            name: "search_meetings",
            arguments: ["query": "redis"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("\"match_kind\""))
        XCTAssertTrue(result.text.contains("Cache planning"))

        let missing = await provider.call(name: "search_meetings", arguments: nil)
        XCTAssertTrue(missing.text.hasPrefix("[invalid_arguments]"))
    }

    func testAskLibraryDelegatesToClosure() async {
        let result = await provider.call(
            name: "ask_library",
            arguments: ["question": "What did we decide about caching?"])
        XCTAssertEqual(result.text, "stub answer")
        XCTAssertEqual(askedQuestions, ["What did we decide about caching?"])

        let empty = await provider.call(
            name: "ask_library",
            arguments: ["question": "   "])
        XCTAssertTrue(empty.text.hasPrefix("[invalid_arguments]"))
    }

    func testUnknownToolName() async {
        let result = await provider.call(name: "delete_everything", arguments: nil)
        XCTAssertTrue(result.text.hasPrefix("[unknown_tool]"))
    }
}
