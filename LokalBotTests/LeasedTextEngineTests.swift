import XCTest
@testable import LokalBot

@MainActor
final class LeasedTextEngineTests: XCTestCase {

    private final class PartialRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ partial: String) {
            lock.withLock { storage.append(partial) }
        }

        var values: [String] {
            lock.withLock { storage }
        }
    }

    private actor CallRecorder {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
        func count(of event: String) -> Int { events.filter { $0 == event }.count }
    }

    private struct RecordingEngine: TextEngine {
        let recorder: CallRecorder
        var displayName: String { "recording-engine" }

        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            await recorder.record("generate")
            return "plain:\(prompt)"
        }

        func generate(system: String, prompt: String, context: [String],
                      schema: [String: Any]) async throws -> String {
            await recorder.record("generate-schema")
            return "schema:\(prompt)"
        }

        func complete(_ request: CompletionRequest) async throws -> String {
            await recorder.record("complete")
            return "complete:\(request.prompt)"
        }

        func completeStreaming(_ request: CompletionRequest,
                               onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
            await recorder.record("stream")
            onPartial("partial-chunk")
            return "stream:\(request.prompt)"
        }
    }

    private struct TestFailure: Error {}

    private struct ThrowingEngine: TextEngine {
        var displayName: String { "throwing-engine" }
        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            throw TestFailure()
        }
    }

    private let modelURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("leased-engine-fake.gguf")

    private func makeBroker(recorder: CallRecorder) -> InferenceBroker {
        var hooks: [InferenceRole: InferenceBroker.RuntimeHooks] = [:]
        for role in InferenceRole.allCases {
            hooks[role] = InferenceBroker.RuntimeHooks(
                ensure: { _ in await recorder.record("ensure:\(role.rawValue)") },
                stop: { await recorder.record("stop:\(role.rawValue)") })
        }
        return InferenceBroker(hooks: hooks, leaseStateSink: { _, _ in })
    }

    private var completionRequest: CompletionRequest {
        CompletionRequest(prompt: "the-prompt", maxTokens: 8, temperature: 0.2,
                          topP: 0.9, topK: 40, minP: 0.05, repeatPenalty: 1.1,
                          seed: 7, stop: [])
    }

    private func makeEngine(recorder: CallRecorder,
                            broker: InferenceBroker) -> LeasedTextEngine {
        LeasedTextEngine(base: RecordingEngine(recorder: recorder), broker: broker,
                         role: .mainLLM, modelURL: modelURL,
                         priority: .background, purpose: "summary")
    }

    func testGenerateEnsuresBeforeBaseCallAndReleasesAfter() async throws {
        let recorder = CallRecorder()
        let broker = makeBroker(recorder: recorder)
        let engine = makeEngine(recorder: recorder, broker: broker)

        let reply = try await engine.generate(system: "s", prompt: "p", context: [])

        XCTAssertEqual(reply, "plain:p")
        let events = await recorder.events
        XCTAssertEqual(events, ["ensure:mainLLM", "generate"])
        let active = await broker.activeLeaseCount(.mainLLM)
        XCTAssertEqual(active, 0)
    }

    func testAllFourProtocolMethodsForwardToBase() async throws {
        let recorder = CallRecorder()
        let broker = makeBroker(recorder: recorder)
        let engine = makeEngine(recorder: recorder, broker: broker)

        let schema = try await engine.generate(system: "s", prompt: "p", context: [],
                                               schema: ["type": "object"])
        XCTAssertEqual(schema, "schema:p")

        let completion = try await engine.complete(completionRequest)
        XCTAssertEqual(completion, "complete:the-prompt")

        let partials = PartialRecorder()
        let streamed = try await engine.completeStreaming(completionRequest) { partials.append($0) }
        XCTAssertEqual(streamed, "stream:the-prompt")
        XCTAssertEqual(partials.values, ["partial-chunk"])

        let ensures = await recorder.count(of: "ensure:mainLLM")
        XCTAssertEqual(ensures, 3)
        let events = await recorder.events
        let baseCalls = events.filter { !$0.hasPrefix("ensure:") && !$0.hasPrefix("stop:") }
        XCTAssertEqual(baseCalls, ["generate-schema", "complete", "stream"])
    }

    func testDisplayNameForwardsWithoutLeasing() async {
        let recorder = CallRecorder()
        let broker = makeBroker(recorder: recorder)
        let engine = makeEngine(recorder: recorder, broker: broker)

        XCTAssertEqual(engine.displayName, "recording-engine")
        let events = await recorder.events
        XCTAssertTrue(events.isEmpty)
    }

    func testBaseEngineErrorStillReleasesLease() async {
        let recorder = CallRecorder()
        let broker = makeBroker(recorder: recorder)
        let engine = LeasedTextEngine(base: ThrowingEngine(), broker: broker,
                                      role: .mainLLM, modelURL: modelURL,
                                      priority: .interactive, purpose: "chat")

        do {
            _ = try await engine.generate(system: "s", prompt: "p", context: [])
            XCTFail("expected the base error to propagate")
        } catch {
            XCTAssertTrue(error is TestFailure)
        }
        let active = await broker.activeLeaseCount(.mainLLM)
        XCTAssertEqual(active, 0)
    }
}
