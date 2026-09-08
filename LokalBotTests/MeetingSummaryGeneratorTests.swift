import XCTest
@testable import LokalBot

final class MeetingSummaryGeneratorTests: XCTestCase {
    private actor Script {
        enum Outcome {
            case value(String)
            case failure(TextEngineError)
        }

        struct Call: Sendable {
            var prompt: String
            var options: TextGenerationOptions
        }

        private var outcomes: [Outcome]
        private var calls: [Call] = []

        init(_ outcomes: [Outcome]) {
            self.outcomes = outcomes
        }

        func next(prompt: String, options: TextGenerationOptions) throws -> String {
            calls.append(Call(prompt: prompt, options: options))
            guard !outcomes.isEmpty else {
                throw TextEngineError.badResponse("script exhausted")
            }
            switch outcomes.removeFirst() {
            case .value(let value):
                return value
            case .failure(let error):
                throw error
            }
        }

        func recordedCalls() -> [Call] {
            calls
        }
    }

    private struct ScriptedEngine: TextEngine {
        let script: Script
        var displayName: String { "Summary test engine" }

        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            try await script.next(prompt: prompt, options: TextGenerationOptions())
        }

        func generate(
            system: String,
            prompt: String,
            context: [String],
            schema: [String: Any],
            options: TextGenerationOptions
        ) async throws -> String {
            try await script.next(prompt: prompt, options: options)
        }
    }

    func testTokenAwareRouteIncludesOutputAndSafetyHeadroom() {
        XCTAssertTrue(MeetingSummaryGenerator.shouldUseSinglePass(
            system: "Summarize.",
            prompt: String(repeating: "useful discussion ", count: 1_000),
            context: [],
            contextTokens: MainLLMRuntimePolicy.contextTokens))
        XCTAssertFalse(MeetingSummaryGenerator.shouldUseSinglePass(
            system: "Summarize.",
            prompt: String(repeating: "useful discussion ", count: 20_000),
            context: [],
            contextTokens: MainLLMRuntimePolicy.contextTokens))
    }

    func testOutputTruncationRetriesOnceWithoutReasoningAndWithMoreOutput() async throws {
        let script = Script([
            .failure(.outputTruncated),
            .value(try claims("Recovered.")),
        ])

        let result = try await generate(script: script, checkpoint: makeCheckpointURL())
        let calls = await script.recordedCalls()

        XCTAssertTrue(result.contains("Recovered."))
        XCTAssertTrue(result.contains("identity unconfirmed"))
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].options.maxTokens, 4_096)
        XCTAssertEqual(calls[0].options.reasoningBudgetTokens, 1_024)
        XCTAssertEqual(calls[1].options.maxTokens, 6_144)
        XCTAssertEqual(calls[1].options.reasoningBudgetTokens, 0)
        XCTAssertTrue(calls[1].prompt.contains("Retry compactly"))
    }

    func testDoubleDirectTruncationSplitsThenSynthesizes() async throws {
        let script = Script([
            .failure(.outputTruncated),
            .failure(.outputTruncated),
            .value(try claims("First-half notes")),
            .value(try claims("Second-half notes")),
            .value(try claims("Final synthesis.")),
        ])

        let result = try await generate(script: script, checkpoint: makeCheckpointURL())
        let calls = await script.recordedCalls()

        XCTAssertTrue(result.contains("Final synthesis."))
        XCTAssertTrue(result.contains("identity unconfirmed"))
        XCTAssertEqual(calls.count, 5)
        XCTAssertTrue(calls[4].prompt.contains("First-half notes"))
        XCTAssertTrue(calls[4].prompt.contains("Second-half notes"))
    }

    func testCheckpointResumesAfterLastCompletedPart() async throws {
        let checkpoint = makeCheckpointURL()
        let firstScript = Script([
            .failure(.outputTruncated),
            .failure(.outputTruncated),
            .value(try claims("Finished first part")),
            .failure(.badResponse("interrupted")),
        ])

        do {
            _ = try await generate(script: firstScript, checkpoint: checkpoint)
            XCTFail("Expected the interrupted second part to fail")
        } catch TextEngineError.badResponse {
            // Expected.
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.path))

        let resumedScript = Script([
            .value(try claims("Finished second part")),
            .value(try claims("Resumed final.")),
        ])
        let result = try await generate(script: resumedScript, checkpoint: checkpoint)
        let resumedCalls = await resumedScript.recordedCalls()

        XCTAssertTrue(result.contains("Resumed final."))
        XCTAssertTrue(result.contains("identity unconfirmed"))
        XCTAssertEqual(resumedCalls.count, 2, "the completed first part must come from disk")
        XCTAssertTrue(resumedCalls[1].prompt.contains("Finished first part"))
        XCTAssertTrue(resumedCalls[1].prompt.contains("Finished second part"))
    }

    func testRepeatedSynthesisTruncationReturnsUsablePartNotes() async throws {
        let script = Script([
            .value(try claims("Grounded part note")),
            .failure(.outputTruncated),
            .failure(.outputTruncated),
        ])

        let result = try await generate(
            script: script,
            checkpoint: makeCheckpointURL(),
            contextTokens: 7_000)

        XCTAssertTrue(result.hasPrefix("## TL;DR"))
        XCTAssertTrue(result.contains("Grounded part note"))
    }

    private func claims(_ text: String) throws -> String {
        let source = sampleTranscript()
        return try SummaryClaimEvidence.encode([.init(section: "TL;DR", text: text,
            speakerID: "me", segmentID: source.segmentID(at: 0), quote: "topic1")])
    }

    private func generate(
        script: Script,
        checkpoint: URL,
        contextTokens: Int = MainLLMRuntimePolicy.contextTokens
    ) async throws -> String {
        try await MeetingSummaryGenerator.generate(
            transcript: sampleTranscript(),
            engine: ScriptedEngine(script: script),
            systemPrompt: "Write complete meeting notes.",
            template: .meeting,
            language: .en,
            userSpeakerLabel: "Me",
            context: [],
            contextTokens: contextTokens,
            checkpointURL: checkpoint)
    }

    private func sampleTranscript() -> Transcript {
        let text = (1...40).map { "topic\($0)" }.joined(separator: " ")
        return Transcript(
            segments: [.init(
                start: 0,
                end: 20,
                speaker: "me",
                text: text,
                confidence: nil)],
            engine: "test")
    }

    private func makeCheckpointURL() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return MeetingSummaryGenerator.checkpointURL(in: root)
    }
}
