import XCTest
@testable import LokalBot

// FakeTransport (shared with AgentSessionControllerTests) lives in
// Helpers/FakeTransport.swift.

final class PiRPCClientTests: XCTestCase {

    func testRequestResolvesOnMatchingID() async throws {
        let transport = FakeTransport()
        let client = PiRPCClient(transport: transport)
        await client.run()

        async let responseTask = client.request(.getState(id: "s1"))
        // Give the request time to hit the wire, then answer it.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(transport.sentLines.contains { $0.contains(#""id":"s1""#) })
        transport.inject(#"{"type":"response","id":"s1","command":"get_state","success":true}"#)
        let response = try await responseTask
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.command, "get_state")
    }

    func testNonResponseLinesFlowToEventStream() async throws {
        let transport = FakeTransport()
        let client = PiRPCClient(transport: transport)
        await client.run()
        var iterator = (await client.events).makeAsyncIterator()
        transport.inject(#"{"type":"agent_start"}"#)
        let event = await iterator.next()
        XCTAssertEqual(event, .agentStart)
    }

    func testInterleavedEventsDoNotStealResponses() async throws {
        let transport = FakeTransport()
        let client = PiRPCClient(transport: transport)
        await client.run()
        async let responseTask = client.request(.prompt(id: "p1", message: "hi", streamingBehavior: nil))
        try await Task.sleep(for: .milliseconds(100))
        transport.inject(#"{"type":"agent_start"}"#)
        transport.inject(#"{"type":"response","id":"p1","command":"prompt","success":true}"#)
        let response = try await responseTask
        XCTAssertEqual(response.id, "p1")
    }

    func testTransportCloseFailsPendingRequests() async throws {
        let transport = FakeTransport()
        let client = PiRPCClient(transport: transport)
        await client.run()
        async let responseTask = client.request(.getState(id: "s2"))
        try await Task.sleep(for: .milliseconds(100))
        transport.close()
        do {
            _ = try await responseTask
            XCTFail("expected throw")
        } catch PiRPCError.transportClosed { // expected
        }
    }

    func testSendResponseWritesWithoutWaiting() async throws {
        let transport = FakeTransport()
        let client = PiRPCClient(transport: transport)
        await client.run()
        try await client.sendResponse(.uiConfirmResponse(requestID: "u1", confirmed: true))
        XCTAssertTrue(transport.sentLines.contains { $0.contains(#""id":"u1""#) && $0.contains(#""confirmed":true"#) })
    }
}
