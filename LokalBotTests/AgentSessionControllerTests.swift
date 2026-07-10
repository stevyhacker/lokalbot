import XCTest
@testable import LokalBot

@MainActor
final class AgentSessionControllerTests: XCTestCase {

    private var transport: FakeTransport!

    private func makeController(backend: AppSettings.SummarizerBackend = .openAICompatible) -> AgentSessionController {
        transport = FakeTransport()
        var settings = AppSettings()
        settings.summarizerBackend = backend
        settings.openAIBaseURL = "http://localhost:1234/v1"
        settings.openAIModel = "test-model"
        let captured = transport!
        return AgentSessionController(
            settings: { settings },
            storage: StorageManager(),
            makeTransport: { _ in captured })
    }

    private func pump() async throws {
        // Let the event-consumption task drain injected lines.
        try await Task.sleep(for: .milliseconds(150))
    }

    func testStartReachesReady() async throws {
        let controller = makeController()
        await controller.start()
        XCTAssertEqual(controller.state, .ready)
    }

    func testUnsupportedBackendFailsWithoutSpawning() async throws {
        let controller = makeController(backend: .appleIntelligence)
        await controller.start()
        guard case .failed(let reason) = controller.state else { return XCTFail() }
        XCTAssertTrue(reason.contains("Apple Intelligence"))
        XCTAssertEqual(controller.recoveryAction, .openModels)
    }

    func testSendFoldsUserAndStreamsAssistant() async throws {
        let controller = makeController()
        await controller.start()
        // send() awaits pi's response ack, so run it concurrently and ack it
        // once the prompt line is on the wire (first request id is "p1").
        let send = Task { await controller.send(prompt: "hello") }
        try await pump()
        XCTAssertTrue(transport.sentLines.contains { $0.contains(#""type":"prompt""#) && $0.contains("hello") })
        transport.inject(#"{"type":"response","id":"p1","command":"prompt","success":true}"#)
        await send.value

        transport.inject(#"{"type":"agent_start"}"#)
        transport.inject(#"{"type":"message_start","message":{"role":"assistant"}}"#)
        transport.inject(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Hi "}}"#)
        transport.inject(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"there"}}"#)
        try await pump()
        XCTAssertEqual(controller.state, .running)
        guard case .assistant(_, let text, let streaming) = controller.items.last else {
            return XCTFail("\(controller.items)")
        }
        XCTAssertEqual(text, "Hi there")
        XCTAssertTrue(streaming)

        transport.inject(#"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Hi there!"}]}}"#)
        transport.inject(#"{"type":"agent_settled"}"#)
        try await pump()
        XCTAssertEqual(controller.state, .ready)
        guard case .assistant(_, let final, let stillStreaming) = controller.items.last else { return XCTFail() }
        XCTAssertEqual(final, "Hi there!")
        XCTAssertFalse(stillStreaming)
    }

    func testConfirmRequestRaisesApprovalCardAndReplies() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"extension_ui_request","id":"u1","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"write\",\"workspace\":\"/tmp/project\",\"path\":\"/tmp/project/note.txt\",\"content\":\"exact content\",\"truncated\":false}"}"#)
        try await pump()
        guard case .approval(let request) = controller.items.last else {
            return XCTFail("\(controller.items)")
        }
        XCTAssertEqual(request.id, "u1")
        XCTAssertEqual(request.tool, "write")
        XCTAssertEqual(request.workspace, "/tmp/project")
        XCTAssertEqual(request.path, "/tmp/project/note.txt")
        XCTAssertEqual(request.content, "exact content")

        await controller.respondToApproval(id: "u1", approved: true, scope: .once)
        try await pump()
        XCTAssertTrue(transport.sentLines.contains {
            $0.contains(#""id":"u1""#) && $0.contains(#""confirmed":true"#)
        })
        XCTAssertFalse(controller.items.contains {
            if case .approval = $0 { return true } else { return false }
        }, "approval card removed after answer")
    }

    func testDenialAddsDeterministicHostNotice() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"extension_ui_request","id":"u1","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"bash\",\"workspace\":\"/tmp\",\"command\":\"rm -rf ./cache\"}"}"#)
        try await pump()

        await controller.respondToApproval(id: "u1", approved: false, scope: .once)
        try await pump()

        XCTAssertTrue(transport.sentLines.contains {
            $0.contains(#""id":"u1""#) && $0.contains(#""confirmed":false"#)
        })
        guard case .notice(_, let text, false) = controller.items.last else {
            return XCTFail("\(controller.items)")
        }
        XCTAssertEqual(text, "You denied this bash request. Nothing changed.")
    }

    func testSessionScopeAutoApprovesRepeats() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"extension_ui_request","id":"u1","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"bash\",\"summary\":\"ls\"}"}"#)
        try await pump()
        await controller.respondToApproval(id: "u1", approved: true, scope: .session)
        transport.inject(#"{"type":"extension_ui_request","id":"u2","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"bash\",\"summary\":\"pwd\"}"}"#)
        try await pump()
        XCTAssertTrue(transport.sentLines.contains {
            $0.contains(#""id":"u2""#) && $0.contains(#""confirmed":true"#)
        }, "second bash auto-approved for the session")
        XCTAssertFalse(controller.items.contains {
            if case .approval(let request) = $0 { return request.id == "u2" } else { return false }
        })
    }

    func testNonConfirmUIRequestIsDeclined() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"extension_ui_request","id":"u3","method":"input","title":"Enter value"}"#)
        try await pump()
        XCTAssertTrue(transport.sentLines.contains {
            $0.contains(#""id":"u3""#) && $0.contains(#""cancelled":true"#)
        })
        guard case .notice(_, let text, _) = controller.items.last else { return XCTFail() }
        XCTAssertTrue(text.contains("unsupported"))
    }

    func testTransportDeathFailsSession() async throws {
        let controller = makeController()
        await controller.start()
        transport.close()
        try await pump()
        guard case .failed = controller.state else { return XCTFail("\(controller.state)") }
        guard case .notice(_, _, let isError) = controller.items.last else { return XCTFail() }
        XCTAssertTrue(isError)
    }

    func testFirstPromptNamesSessionAndDraftRequiresCloseConfirmation() async throws {
        let controller = makeController()
        controller.draft = "unsent"
        XCTAssertTrue(controller.requiresCloseConfirmation)
        controller.draft = ""

        await controller.start()
        let send = Task {
            await controller.send(prompt: "Summarize the action items from today's meeting")
        }
        try await pump()
        transport.inject(#"{"type":"response","id":"p1","command":"prompt","success":true}"#)
        await send.value

        XCTAssertEqual(controller.sessionTitle, "Summarize the action items from…")
        XCTAssertTrue(controller.requiresCloseConfirmation)
    }

    func testResumeLaunchesContinueAndRestoresVisibleHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-resume-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = StorageManager(rootURL: root.appendingPathComponent("library", isDirectory: true))
        let header = #"{"type":"session","id":"saved","cwd":"\#(storage.rootURL.path)"}"#
        try Data((header + "\n").utf8).write(to: sessions.appendingPathComponent("saved.jsonl"))

        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "http://127.0.0.1:1234/v1"
        settings.openAIModel = "resume-test"
        var transports: [FakeTransport] = []
        var plans: [PiLaunchPlan] = []
        let controller = AgentSessionController(
            settings: { settings },
            storage: storage,
            sessionsDirectory: sessions,
            makeTransport: { plan in
                plans.append(plan)
                let transport = FakeTransport()
                transports.append(transport)
                return transport
            })

        await controller.start()
        XCTAssertTrue(controller.canResumePreviousSession)

        let resume = Task { await controller.resumePreviousSession() }
        for _ in 0..<20 where transports.count < 2 {
            try await Task.sleep(for: .milliseconds(25))
        }
        let resumedTransport = try XCTUnwrap(transports.last)
        for _ in 0..<20 where !resumedTransport.sentLines.contains(where: { $0.contains("get_messages") }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        resumedTransport.inject(#"{"type":"response","id":"history1","command":"get_messages","success":true,"data":{"messages":[{"role":"user","content":"Review yesterday's decisions"},{"role":"assistant","content":[{"type":"text","text":"Here are the decisions."}]}]}}"#)
        await resume.value

        XCTAssertTrue(try XCTUnwrap(plans.last).arguments.contains("--continue"))
        XCTAssertEqual(controller.sessionTitle, "Review yesterday's decisions")
        XCTAssertTrue(controller.items.contains {
            if case .user(_, "Review yesterday's decisions") = $0 { return true }
            return false
        })
        XCTAssertTrue(controller.items.contains {
            if case .assistant(_, "Here are the decisions.", false) = $0 { return true }
            return false
        })
    }
}
