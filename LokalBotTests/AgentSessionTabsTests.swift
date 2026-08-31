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

    func testLiveSessionCountIsBounded() {
        let factory = Factory(root: root)
        let sessions = AgentSessionTabs { factory.makeController() }
        for _ in 0..<(AgentSessionTabs.maximumLiveSessions + 3) {
            _ = sessions.addSession()
        }
        XCTAssertEqual(sessions.tabs.count, AgentSessionTabs.maximumLiveSessions)
        XCTAssertEqual(factory.transports.count, AgentSessionTabs.maximumLiveSessions)
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

    func testLoadsAndOpensExactSavedSessionInBlankTab() async throws {
        let factory = Factory(root: root)
        try FileManager.default.createDirectory(
            at: factory.sessionsDirectory,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: factory.storage.rootURL, withIntermediateDirectories: true)
        let savedFile = factory.sessionsDirectory.appendingPathComponent("saved.jsonl")
        try writeSession(
            id: "saved-session",
            title: "Reopen this conversation",
            workspace: factory.storage.rootURL,
            to: savedFile)
        let sessions = AgentSessionTabs { factory.makeController() }
        let originalTab = try XCTUnwrap(sessions.selectedTab)

        let loaded = try await sessions.loadSavedSessions()
        let saved = try XCTUnwrap(loaded.first)
        let opening = Task { try await sessions.openSavedSession(saved) }
        let transport = try XCTUnwrap(factory.transports.first)
        for _ in 0..<20 where !transport.sentLines.contains(where: { $0.contains("get_messages") }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        transport.inject(#"{"type":"response","id":"history1","command":"get_messages","success":true,"data":{"messages":[{"role":"user","content":"Reopen this conversation"}]}}"#)
        try await opening.value

        XCTAssertEqual(sessions.tabs.count, 1, "a blank selected tab should be reused")
        XCTAssertEqual(sessions.selectedID, originalTab.id)
        XCTAssertEqual(originalTab.controller.activeSessionFile, savedFile)
        XCTAssertEqual(originalTab.controller.sessionTitle, "Reopen this conversation")
        XCTAssertTrue(sessions.isOpen(saved))
        let plan = try XCTUnwrap(factory.plans.first)
        let sessionIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--session"))
        XCTAssertEqual(plan.arguments[sessionIndex + 1], savedFile.path)

        do {
            try await sessions.openSavedSession(saved)
            XCTFail("expected the duplicate session to be rejected")
        } catch AgentSavedSessionOpenError.alreadyOpen {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func writeSession(
        id: String,
        title: String,
        workspace: URL,
        to file: URL
    ) throws {
        let records: [[String: Any]] = [
            [
                "type": "session",
                "id": id,
                "timestamp": "2026-08-05T20:52:04.304Z",
                "cwd": workspace.path,
            ],
            [
                "type": "message",
                "message": [
                    "role": "user",
                    "content": title,
                    "timestamp": 1_785_963_156_269 as Int64,
                ],
            ],
        ]
        let lines = try records.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    }
}

@MainActor
private final class Factory {
    let storage: StorageManager
    let sessionsDirectory: URL
    private(set) var transports: [FakeTransport] = []
    private(set) var plans: [PiLaunchPlan] = []

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
            makeTransport: { plan in
                self.plans.append(plan)
                return transport
            })
    }
}
