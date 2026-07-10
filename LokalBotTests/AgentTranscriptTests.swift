import XCTest
@testable import LokalBot

/// Folding rules: streaming deltas accumulate into one assistant bubble,
/// message_end replaces it with the final text, tool events drive one card
/// per toolCallId, and empty assistant bubbles (tool-call-only turns) are
/// dropped.
final class AgentTranscriptTests: XCTestCase {

    func testStreamingAssistantMessageLifecycle() {
        var folder = AgentTranscriptFolder()
        folder.fold(.agentStart)
        XCTAssertTrue(folder.isAgentRunning)
        folder.fold(.messageStart(role: "assistant"))
        folder.fold(.messageUpdate(.textDelta("Hello")))
        folder.fold(.messageUpdate(.textDelta(" world")))
        guard case .assistant(_, let streamed, let isStreaming) = folder.items.last else {
            return XCTFail("expected assistant item, got \(folder.items)")
        }
        XCTAssertEqual(streamed, "Hello world")
        XCTAssertTrue(isStreaming)
        folder.fold(.messageEnd(role: "assistant", text: "Hello world!"))
        folder.fold(.agentSettled)
        XCTAssertFalse(folder.isAgentRunning)
        XCTAssertEqual(folder.items.count, 1)
        guard case .assistant(_, let final, let stillStreaming) = folder.items[0] else {
            return XCTFail()
        }
        XCTAssertEqual(final, "Hello world!", "message_end text wins over accumulated deltas")
        XCTAssertFalse(stillStreaming)
    }

    func testDeltaWithoutMessageStartCreatesBubble() {
        var folder = AgentTranscriptFolder()
        folder.fold(.messageUpdate(.textDelta("hi")))
        guard case .assistant(_, "hi", true) = folder.items[0] else { return XCTFail() }
    }

    func testEmptyAssistantBubbleIsDroppedOnMessageEnd() {
        var folder = AgentTranscriptFolder()
        folder.fold(.messageStart(role: "assistant"))
        folder.fold(.messageEnd(role: "assistant", text: ""))
        XCTAssertTrue(folder.items.isEmpty, "tool-call-only turn leaves no empty bubble")
    }

    func testNonAssistantMessagesAreIgnored() {
        var folder = AgentTranscriptFolder()
        folder.fold(.messageStart(role: "user"))
        folder.fold(.messageEnd(role: "toolResult", text: "x"))
        XCTAssertTrue(folder.items.isEmpty)
    }

    func testToolCardLifecycle() {
        var folder = AgentTranscriptFolder()
        folder.fold(.toolExecutionStart(callID: "call_1", name: "bash", argsJSON: #"{"command":"ls"}"#))
        folder.fold(.toolExecutionUpdate(callID: "call_1", output: "partial"))
        folder.fold(.toolExecutionEnd(callID: "call_1", output: "total 48", isError: false))
        XCTAssertEqual(folder.items, [.tool(id: "call_1", name: "bash", argsJSON: #"{"command":"ls"}"#,
                                            output: "total 48", status: .succeeded)])
    }

    func testFailedToolGetsFailedStatus() {
        var folder = AgentTranscriptFolder()
        folder.fold(.toolExecutionStart(callID: "call_2", name: "write", argsJSON: "{}"))
        folder.fold(.toolExecutionEnd(callID: "call_2", output: "denied", isError: true))
        guard case .tool(_, _, _, _, .failed) = folder.items[0] else { return XCTFail() }
    }

    func testApprovalAddAndResolve() {
        var folder = AgentTranscriptFolder()
        let request = approvalRequest(id: "uuid-1", command: "rm x")
        folder.addApproval(request)
        XCTAssertEqual(folder.items, [.approval(request)])
        folder.resolveApproval(requestID: "uuid-1")
        XCTAssertTrue(folder.items.isEmpty)
    }

    func testResolveApprovalKeepsStreamingDeltasOnTheRightBubble() {
        var folder = AgentTranscriptFolder()
        folder.addApproval(approvalRequest(id: "uuid-1", command: "ls"))
        folder.fold(.messageStart(role: "assistant"))
        folder.fold(.messageUpdate(.textDelta("Hello")))
        // Removing the card shifts the array under the streaming bubble; the
        // assistant is now the LAST item, so a stale raw index would be out
        // of range on the next delta.
        folder.resolveApproval(requestID: "uuid-1")
        folder.fold(.messageUpdate(.textDelta(" world")))
        XCTAssertEqual(folder.items.count, 1)
        guard case .assistant(_, "Hello world", true) = folder.items[0] else {
            return XCTFail("expected one streaming assistant bubble, got \(folder.items)")
        }
        folder.fold(.messageEnd(role: "assistant", text: ""))
        guard case .assistant(_, "Hello world", false) = folder.items[0] else {
            return XCTFail("expected finalized bubble, got \(folder.items)")
        }
    }

    func testUserPromptAndNotices() {
        var folder = AgentTranscriptFolder()
        folder.noteUserPrompt("do the thing")
        folder.appendNotice("Denied bash", isError: false)
        folder.fold(.extensionError(message: "boom"))
        XCTAssertEqual(folder.items.count, 3)
        guard case .notice(_, "boom", true) = folder.items[2] else { return XCTFail() }
    }

    func testAgentSettledFinishesStreamingBubble() {
        var folder = AgentTranscriptFolder()
        folder.fold(.messageUpdate(.textDelta("partial answer")))
        folder.fold(.agentSettled)   // e.g. user aborted mid-stream: no message_end
        guard case .assistant(_, "partial answer", false) = folder.items[0] else { return XCTFail() }
    }

    private func approvalRequest(id: String, command: String) -> AgentApprovalRequest {
        AgentApprovalRequest(
            id: id,
            tool: "bash",
            workspace: "/tmp",
            path: nil,
            command: command,
            content: nil,
            edits: [],
            summary: nil,
            isTruncated: false)
    }
}
