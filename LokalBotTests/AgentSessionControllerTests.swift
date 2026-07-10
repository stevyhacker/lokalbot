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
        transport.inject(#"{"type":"extension_ui_request","id":"u1","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"bash\",\"summary\":\"rm -rf /tmp/x\"}"}"#)
        try await pump()
        guard case .approval(let id, let tool, let summary) = controller.items.last else {
            return XCTFail("\(controller.items)")
        }
        XCTAssertEqual(id, "u1")
        XCTAssertEqual(tool, "bash")
        XCTAssertEqual(summary, "rm -rf /tmp/x")

        await controller.respondToApproval(id: "u1", approved: true, scope: .once)
        try await pump()
        XCTAssertTrue(transport.sentLines.contains {
            $0.contains(#""id":"u1""#) && $0.contains(#""confirmed":true"#)
        })
        XCTAssertFalse(controller.items.contains {
            if case .approval = $0 { return true } else { return false }
        }, "approval card removed after answer")
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
            if case .approval(let id, _, _) = $0 { return id == "u2" } else { return false }
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
}
