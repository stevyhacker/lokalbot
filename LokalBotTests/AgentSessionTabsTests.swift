import XCTest
@testable import LokalBot

@MainActor
final class AgentSessionTabsTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-tabs-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    func testAddingTabCreatesIndependentSelectedSession() async throws {
        let factory = Factory(root: root)
        let sessions = AgentSessionTabs { factory.makeController() }
        let first = try XCTUnwrap(sessions.selectedTab)
        let second = sessions.addSession()

        XCTAssertEqual(sessions.tabs.count, 2)
        XCTAssertEqual(sessions.selectedID, second.id)
        XCTAssertFalse(first.controller === second.controller)

        await first.controller.start()
        await second.controller.start()
        XCTAssertEqual(first.controller.state, .ready)
        XCTAssertEqual(second.controller.state, .ready)

        let firstSend = Task { await first.controller.send(prompt: "first tab") }
        let secondSend = Task { await second.controller.send(prompt: "second tab") }
        try await Task.sleep(for: .milliseconds(50))
        factory.transports[0].inject(#"{"type":"response","id":"p1","command":"prompt","success":true}"#)
        factory.transports[1].inject(#"{"type":"response","id":"p1","command":"prompt","success":true}"#)
        await firstSend.value
        await secondSend.value

        XCTAssertTrue(first.controller.items.contains {
            if case .user(_, "first tab") = $0 { return true }
            return false
        })
        XCTAssertFalse(first.controller.items.contains {
            if case .user(_, "second tab") = $0 { return true }
            return false
        })
        XCTAssertTrue(second.controller.items.contains {
            if case .user(_, "second tab") = $0 { return true }
            return false
        })
    }

    func testClosingTabStopsOnlyThatSessionAndKeepsNeighborSelected() async {
        let factory = Factory(root: root)
        let sessions = AgentSessionTabs { factory.makeController() }
        let first = sessions.tabs[0]
        let second = sessions.addSession()
        await first.controller.start()
        await second.controller.start()

        await sessions.close(first.id)

        XCTAssertEqual(sessions.tabs.map(\.id), [second.id])
        XCTAssertEqual(sessions.selectedID, second.id)
        XCTAssertEqual(first.controller.state, .idle)
        XCTAssertEqual(second.controller.state, .ready)
    }

    func testClosingFinalTabCreatesFreshSession() async {
        let factory = Factory(root: root)
        let sessions = AgentSessionTabs { factory.makeController() }
        let original = sessions.tabs[0]

        await sessions.close(original.id)

        XCTAssertEqual(sessions.tabs.count, 1)
        XCTAssertNotEqual(sessions.tabs[0].id, original.id)
        XCTAssertEqual(sessions.selectedID, sessions.tabs[0].id)
        XCTAssertEqual(original.controller.state, .idle)
    }

    func testShutdownAllStopsEverySessionWithoutCreatingReplacement() async {
        let factory = Factory(root: root)
        let sessions = AgentSessionTabs { factory.makeController() }
        let first = sessions.tabs[0]
        let second = sessions.addSession()
        await first.controller.start()
        await second.controller.start()

        await sessions.shutdownAll()

        XCTAssertTrue(sessions.tabs.isEmpty)
        XCTAssertEqual(first.controller.state, .idle)
        XCTAssertEqual(second.controller.state, .idle)
    }

    func testClearSavedHistoryStopsSessionsRemovesFilesAndCreatesFreshTab() async throws {
        let factory = Factory(root: root)
        try FileManager.default.createDirectory(
            at: factory.sessionsDirectory, withIntermediateDirectories: true)
        try Data("history".utf8).write(
            to: factory.sessionsDirectory.appendingPathComponent("saved.jsonl"))
        let sessions = AgentSessionTabs { factory.makeController() }
        let original = sessions.tabs[0]
        await original.controller.start()

        try await sessions.clearSavedHistory()

        XCTAssertEqual(original.controller.state, .idle)
        XCTAssertEqual(sessions.tabs.count, 1)
        XCTAssertNotEqual(sessions.tabs[0].id, original.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: factory.sessionsDirectory,
            includingPropertiesForKeys: nil), [])
    }
}

@MainActor
private final class Factory {
    let storage: StorageManager
    let sessionsDirectory: URL
    private(set) var transports: [FakeTransport] = []

    init(root: URL) {
        storage = StorageManager(rootURL: root)
        sessionsDirectory = root.appendingPathComponent("agent-sessions", isDirectory: true)
    }

    func makeController() -> AgentSessionController {
        let transport = FakeTransport()
        transports.append(transport)
        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "http://127.0.0.1:1234/v1"
        settings.openAIModel = "tabs-test"
        return AgentSessionController(
            settings: { settings },
            storage: storage,
            sessionsDirectory: sessionsDirectory,
            makeTransport: { _ in transport })
    }
}
