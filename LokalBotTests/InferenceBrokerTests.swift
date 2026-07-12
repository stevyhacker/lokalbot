import XCTest
@testable import LokalBot

@MainActor
final class InferenceBrokerTests: XCTestCase {

    private actor HookRecorder {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
        func count(of event: String) -> Int { events.filter { $0 == event }.count }
    }

    @MainActor
    private final class SinkRecorder {
        private(set) var pinnedHistory: [Set<String>] = []
        private(set) var descriptionsHistory: [[String: [String]]] = []
        func record(pinned: Set<String>, descriptions: [String: [String]]) {
            pinnedHistory.append(pinned)
            descriptionsHistory.append(descriptions)
        }
        var lastPinned: Set<String> { pinnedHistory.last ?? [] }
        var lastDescriptions: [String: [String]] { descriptionsHistory.last ?? [:] }
    }

    private struct TestFailure: Error {}

    private let modelURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("broker-test-fake.gguf")

    private func makeBroker(recorder: HookRecorder, sink: SinkRecorder,
                            linger: TimeInterval = 0.05,
                            failingRoles: Set<InferenceRole> = []) -> InferenceBroker {
        var hooks: [InferenceRole: InferenceBroker.RuntimeHooks] = [:]
        for role in InferenceRole.allCases {
            hooks[role] = InferenceBroker.RuntimeHooks(
                ensure: { _ in
                    if failingRoles.contains(role) { throw TestFailure() }
                    await recorder.record("ensure:\(role.rawValue)")
                },
                stop: { await recorder.record("stop:\(role.rawValue)") })
        }
        return InferenceBroker(
            hooks: hooks,
            lingerSeconds: Dictionary(uniqueKeysWithValues:
                InferenceRole.allCases.map { ($0, linger) }),
            leaseStateSink: { pinned, descriptions in
                sink.record(pinned: pinned, descriptions: descriptions)
            })
    }

    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return await condition()
    }

    func testLeaseBootsRuntimePinsAndCounts() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink)

        let lease = try await broker.lease(.mainLLM, model: modelURL,
                                           priority: .interactive, purpose: "chat")

        let ensures = await recorder.count(of: "ensure:mainLLM")
        XCTAssertEqual(ensures, 1)
        XCTAssertEqual(sink.lastPinned, ["llama-server:17872"])
        XCTAssertEqual(sink.lastDescriptions["llama-server:17872"], ["chat (interactive)"])
        let active = await broker.activeLeaseCount(.mainLLM)
        XCTAssertEqual(active, 1)
        await broker.release(lease)
    }

    func testReleaseUnpinsImmediatelyThenStopsAfterLinger() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink, linger: 0.05)

        let lease = try await broker.lease(.mainLLM, model: modelURL,
                                           priority: .background, purpose: "summary")
        await broker.release(lease)

        XCTAssertEqual(sink.lastPinned, [])
        let stoppedBeforeLinger = await recorder.count(of: "stop:mainLLM")
        XCTAssertEqual(stoppedBeforeLinger, 0)
        let stopped = await waitUntil { await recorder.count(of: "stop:mainLLM") == 1 }
        XCTAssertTrue(stopped)
    }

    func testNewLeaseCancelsPendingLinger() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink, linger: 0.2)

        let first = try await broker.lease(.mainLLM, model: modelURL,
                                           priority: .background, purpose: "summary")
        await broker.release(first)
        let second = try await broker.lease(.mainLLM, model: modelURL,
                                            priority: .interactive, purpose: "chat")

        try await Task.sleep(nanoseconds: 500_000_000)
        let stops = await recorder.count(of: "stop:mainLLM")
        XCTAssertEqual(stops, 0)
        await broker.release(second)
    }

    func testEnsureFailureLeavesNoLeaseOrPin() async {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink,
                                failingRoles: [.mainLLM])

        do {
            _ = try await broker.lease(.mainLLM, model: modelURL,
                                       priority: .interactive, purpose: "chat")
            XCTFail("expected the ensure failure to propagate")
        } catch {
            XCTAssertTrue(error is TestFailure)
        }
        XCTAssertEqual(sink.lastPinned, [])
        let active = await broker.activeLeaseCount(.mainLLM)
        XCTAssertEqual(active, 0)
    }

    func testWithLeaseReleasesOnSuccessAndOnThrow() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink)

        let value = try await broker.withLease(.embedder, model: modelURL,
                                               priority: .background,
                                               purpose: "embeddings") { 42 }
        XCTAssertEqual(value, 42)
        var active = await broker.activeLeaseCount(.embedder)
        XCTAssertEqual(active, 0)

        do {
            _ = try await broker.withLease(.embedder, model: modelURL,
                                           priority: .background,
                                           purpose: "embeddings") { () async throws -> Int in
                throw TestFailure()
            }
            XCTFail("expected the body error to propagate")
        } catch {
            XCTAssertTrue(error is TestFailure)
        }
        active = await broker.activeLeaseCount(.embedder)
        XCTAssertEqual(active, 0)
        XCTAssertEqual(sink.lastPinned, [])
    }

    func testTTLLeaseExpiresOnItsOwn() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink, linger: 0.05)

        _ = try await broker.lease(.mainLLM, model: modelURL, priority: .agent,
                                   purpose: "ask_library", expiresAfter: 0.05)

        let released = await waitUntil { await broker.activeLeaseCount(.mainLLM) == 0 }
        XCTAssertTrue(released)
        let stopped = await waitUntil { await recorder.count(of: "stop:mainLLM") == 1 }
        XCTAssertTrue(stopped)
    }

    func testSecondLeaseOnSameRoleKeepsRuntimeAlive() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink, linger: 0.05)

        let chat = try await broker.lease(.mainLLM, model: modelURL,
                                          priority: .interactive, purpose: "chat")
        let summary = try await broker.lease(.mainLLM, model: modelURL,
                                             priority: .background, purpose: "summary")
        XCTAssertEqual(sink.lastDescriptions["llama-server:17872"],
                       ["chat (interactive)", "summary (background)"])

        await broker.release(chat)
        try await Task.sleep(nanoseconds: 300_000_000)
        let stopsWhileHeld = await recorder.count(of: "stop:mainLLM")
        XCTAssertEqual(stopsWhileHeld, 0)
        XCTAssertEqual(sink.lastPinned, ["llama-server:17872"])

        await broker.release(summary)
        let stopped = await waitUntil { await recorder.count(of: "stop:mainLLM") == 1 }
        XCTAssertTrue(stopped)
    }
}
