import XCTest
@testable import LokalBot

final class MeetingOutcomesGeneratorTests: XCTestCase {
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
        var displayName: String { "Outcomes test engine" }

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

    func testLongTranscriptCoversTailAndExtractsLateAction() async throws {
        let transcript = longTranscript()
        let tailIndex = transcript.segments.count - 1
        let tailID = transcript.segmentID(at: tailIndex)
        let chunks = MeetingOutcomesGenerator.makeChunks(
            transcript: transcript,
            userSpeakerLabel: "Me",
            context: [],
            contextTokens: 5_000)
        let covered = Set(chunks.flatMap(\.segmentIDs))
        let expected = Set(transcript.segments.indices.map(transcript.segmentID))
        let tailChunk = try XCTUnwrap(chunks.firstIndex { $0.segmentIDs.contains(tailID) })
        let empty = #"{"action_items":[],"decisions":[],"open_questions":[]}"#
        let action = """
            {"action_items":[{"text":"Send the launch plan","owner":"Me","due":"",
            "for_user":true,"importance":5,"source_segment_ids":["\(tailID)"]}],
            "decisions":[],"open_questions":[]}
            """
        let responses = chunks.indices.map { index in
            Script.Outcome.value(index == tailChunk ? action : empty)
        }
        let script = Script(responses)

        let result = try await generate(
            transcript: transcript,
            script: script,
            contextTokens: 5_000)
        let calls = await script.recordedCalls()

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(covered, expected, "every non-empty source segment must be scanned")
        XCTAssertEqual(result.actionItems.map(\.text), ["Send the launch plan"])
        XCTAssertEqual(result.actionItems.first?.citations.map(\.segmentID), [tailID])
        XCTAssertEqual(calls.count, chunks.count)
        XCTAssertTrue(calls.allSatisfy { $0.options.maxTokens == 2_048 })
        XCTAssertTrue(calls.allSatisfy { $0.options.reasoningBudgetTokens == 0 })
        XCTAssertTrue(calls.allSatisfy { $0.options.temperature == 0 })
        XCTAssertFalse(MeetingOutcomesGenerator.canUseSinglePass(
            transcript: transcript,
            userSpeakerLabel: "Me",
            context: [],
            contextTokens: 5_000))
    }

    func testTruncatedChunkRetriesCompactlyWithoutReasoning() async throws {
        let transcript = Transcript(
            segments: [
                .init(start: 12, end: 18, speaker: "me", text: "I will send the plan."),
            ],
            engine: "fixture")
        let sourceID = transcript.segmentID(at: 0)
        let script = Script([
            .failure(.outputTruncated),
            .value("""
                {"action_items":[{"text":"Send the plan","owner":"Me","due":"",
                "for_user":true,"importance":5,"source_segment_ids":["\(sourceID)"]}],
                "decisions":[],"open_questions":[]}
                """),
        ])

        let result = try await generate(transcript: transcript, script: script)
        let calls = await script.recordedCalls()

        XCTAssertEqual(result.actionItems.map(\.text), ["Send the plan"])
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].options.maxTokens, 2_048)
        XCTAssertEqual(calls[1].options.maxTokens, 3_072)
        XCTAssertEqual(calls[1].options.reasoningBudgetTokens, 0)
        XCTAssertTrue(calls[1].prompt.contains("Retry compactly"), calls[1].prompt)
    }

    func testMergeDeduplicatesOverlapAndDoesNotRepeatActionAsDecision() {
        let citation = OutcomeSourceCitation(
            segmentID: "segment-0001-0000012000-0000018000",
            start: 12,
            end: 18,
            speaker: "me",
            excerpt: "I will share the project repository")
        var first = MeetingOutcomes()
        first.actionItems = [
            .init(
                text: "Share the project repository",
                owner: "Me",
                isForUser: true,
                importance: 2,
                citations: [citation]),
        ]
        first.decisionRecords = [
            .init(text: "Share the project repository with Stevan", citations: [citation]),
        ]
        var second = MeetingOutcomes()
        second.actionItems = [
            .init(
                text: "Share the project repository with Stevan",
                owner: "Me",
                isForUser: true,
                importance: 5,
                citations: [citation]),
            .init(
                text: "Review the repository",
                owner: "Ricky",
                isForUser: false,
                citations: [OutcomeSourceCitation(
                    segmentID: "segment-0002-0000020000-0000024000",
                    start: 20,
                    end: 24,
                    speaker: "them",
                    excerpt: "I will review it")]),
        ]

        let merged = MeetingOutcomesGenerator.merge([first, second])

        XCTAssertEqual(merged.actionItems.count, 2)
        XCTAssertEqual(merged.actionItems.first?.text, "Share the project repository with Stevan")
        XCTAssertEqual(merged.actionItems.first?.owner, "Me")
        XCTAssertEqual(merged.actionItems.first?.importance, 5)
        XCTAssertTrue(merged.decisionRecords.isEmpty)
    }

    func testCheckpointResumesAfterCompletedChunks() async throws {
        let transcript = longTranscript()
        let chunks = MeetingOutcomesGenerator.makeChunks(
            transcript: transcript,
            userSpeakerLabel: "Me",
            context: [],
            contextTokens: 5_000)
        XCTAssertGreaterThan(chunks.count, 1)
        let checkpoint = makeCheckpointURL()
        let empty = #"{"action_items":[],"decisions":[],"open_questions":[]}"#
        let firstScript = Script([
            .value(empty),
            .failure(.badResponse("interrupted")),
        ])

        do {
            _ = try await generate(
                transcript: transcript,
                script: firstScript,
                contextTokens: 5_000,
                checkpoint: checkpoint)
            XCTFail("Expected the interrupted second chunk to fail")
        } catch TextEngineError.badResponse {
            // Expected.
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.path))

        let resumedScript = Script(
            Array(repeating: .value(empty), count: chunks.count - 1))
        _ = try await generate(
            transcript: transcript,
            script: resumedScript,
            contextTokens: 5_000,
            checkpoint: checkpoint)
        let resumedCalls = await resumedScript.recordedCalls()

        XCTAssertEqual(resumedCalls.count, chunks.count - 1)
    }

    private func generate(
        transcript: Transcript,
        script: Script,
        contextTokens: Int = MainLLMRuntimePolicy.contextTokens,
        checkpoint: URL? = nil
    ) async throws -> MeetingOutcomes {
        try await MeetingOutcomesGenerator.generate(
            transcript: transcript,
            engine: ScriptedEngine(script: script),
            userSpeakerLabel: "Me",
            context: [],
            contextTokens: contextTokens,
            meetingID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            checkpointURL: checkpoint ?? makeCheckpointURL())
    }

    private func longTranscript() -> Transcript {
        let filler = (1...36).map { "context\($0)" }.joined(separator: " ")
        var segments = (0..<72).map { index in
            Transcript.Segment(
                start: Double(index) * 15,
                end: Double(index) * 15 + 10,
                speaker: index.isMultiple(of: 2) ? "me" : "them",
                text: filler,
                confidence: nil)
        }
        segments.append(.init(
            start: 1_313,
            end: 1_324,
            speaker: "me",
            text: "I will send the launch plan after this call.",
            confidence: nil))
        return Transcript(segments: segments, engine: "fixture")
    }

    private func makeCheckpointURL() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return MeetingOutcomesGenerator.checkpointURL(in: root)
    }
}
