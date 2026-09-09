import XCTest
@testable import LokalBot

final class MeetingSummaryGeneratorTests: XCTestCase {
    private actor Script {
        enum Outcome {
            case value(String)
            case failure(TextEngineError)
            case cancelled
        }

        struct Call: Sendable {
            var system: String
            var prompt: String
            var options: TextGenerationOptions
        }

        private var outcomes: [Outcome]
        private var calls: [Call] = []

        init(_ outcomes: [Outcome]) {
            self.outcomes = outcomes
        }

        func next(system: String, prompt: String, options: TextGenerationOptions) throws -> String {
            calls.append(Call(system: system, prompt: prompt, options: options))
            guard !outcomes.isEmpty else {
                throw TextEngineError.badResponse("script exhausted")
            }
            switch outcomes.removeFirst() {
            case .value(let value):
                return value
            case .failure(let error):
                throw error
            case .cancelled:
                throw CancellationError()
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
            try await script.next(system: system, prompt: prompt, options: TextGenerationOptions())
        }

        func generate(
            system: String,
            prompt: String,
            context: [String],
            schema: [String: Any],
            options: TextGenerationOptions
        ) async throws -> String {
            try await script.next(system: system, prompt: prompt, options: options)
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
        XCTAssertTrue(result.contains("**You:**"))
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
        XCTAssertTrue(result.contains("**You:**"))
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
        XCTAssertTrue(result.contains("**You:**"))
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

    func testInvalidQuoteRetriesWithoutEchoingRejectedOutputAndSavesOnlyRepair() async throws {
        let checkpoint = makeCheckpointURL()
        let script = Script([
            .value(try claims("Unsupported claim", quote: "invented private model output")),
            .value(try claims("Recovered.")),
        ])

        let result = try await generate(script: script, checkpoint: checkpoint)
        let calls = await script.recordedCalls()
        XCTAssertTrue(result.contains("Recovered."))
        XCTAssertFalse(result.contains("Unsupported claim"))
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[1].prompt.contains("quote does not exactly match"))
        XCTAssertFalse(calls[1].prompt.contains("invented private model output"))
        XCTAssertEqual(calls[1].options.reasoningBudgetTokens, 0)
        XCTAssertEqual(calls[1].options.temperature, 0)
        let artifact = try JSONDecoder().decode(SummaryClaimEvidence.Artifact.self, from: Data(contentsOf:
            checkpoint.deletingLastPathComponent().appendingPathComponent("summary.claims.partial.json")))
        XCTAssertEqual(artifact.claims.map(\.text), ["Recovered."])
    }

    func testMarkdownResponseRepairsToClaimsJSON() async throws {
        let script = Script([.value("## TL;DR\nThe meeting covered several topics."), .value(try claims("Valid JSON"))])
        let result = try await generate(script: script, checkpoint: makeCheckpointURL())
        let calls = await script.recordedCalls()
        XCTAssertTrue(result.contains("Valid JSON"))
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[1].prompt.contains("required claims JSON"))
    }

    func testRepeatedInvalidSpeakerStopsAfterOneRepairAndDoesNotSaveClaims() async throws {
        let checkpoint = makeCheckpointURL()
        let wrong = try claims("Wrong owner", speakerID: "other-speaker")
        let script = Script([.value(wrong), .value(wrong)])
        do {
            _ = try await generate(script: script, checkpoint: checkpoint)
            XCTFail("An invalid speaker must never be accepted after retry")
        } catch let error as SummaryClaimEvidence.ValidationError {
            XCTAssertEqual(error.reason, .speakerMismatch)
            XCTAssertEqual(error.claimNumber, 1)
            XCTAssertFalse(error.localizedDescription.contains("LLM server error"))
            XCTAssertFalse(error.localizedDescription.contains("other-speaker"))
        }
        let calls = await script.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            checkpoint.deletingLastPathComponent().appendingPathComponent("summary.claims.partial.json").path))
    }

    func testTruncationDoesNotConsumeTheCitationRepairAllowance() async throws {
        let script = Script([
            .failure(.outputTruncated),
            .value(try claims("")),
            .value(try claims("Repaired after truncation")),
        ])
        let result = try await generate(script: script, checkpoint: makeCheckpointURL())
        let calls = await script.recordedCalls()
        XCTAssertTrue(result.contains("Repaired after truncation"))
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls[2].prompt.contains("Retry compactly"))
        XCTAssertTrue(calls[2].prompt.contains("claim text is empty or too long"))
    }

    func testMixedFailureRecoveryStillStopsAfterOneAttemptPerFailureMode() async throws {
        let invalid = try claims("Wrong section", section: "Action items")
        let script = Script([.failure(.outputTruncated), .value(invalid), .value(invalid)])
        do {
            _ = try await generate(script: script, checkpoint: makeCheckpointURL())
            XCTFail("Repeated invalid claims must not start an unbounded repair loop")
        } catch let error as SummaryClaimEvidence.ValidationError {
            XCTAssertEqual(error.reason, .invalidSection)
        }
        let calls = await script.recordedCalls()
        XCTAssertEqual(calls.count, 3)
    }

    func testChunkRejectsCitationFromAnotherPartAndCheckpointsOnlyTheRepair() async throws {
        let source = twoPartTranscript()
        let checkpoint = makeCheckpointURL()
        let first = try claims("First part", source: source, quote: "First evidence.")
        let second = try claims("Second part", source: source, segmentIndex: 1, quote: "Second evidence.")
        let script = Script([
            .failure(.outputTruncated), .failure(.outputTruncated),
            .value(second), .value(first), .value(second), .value(first),
        ])
        _ = try await generate(script: script, checkpoint: checkpoint, transcript: source)
        let calls = await script.recordedCalls()
        XCTAssertEqual(calls.count, 6)
        XCTAssertTrue(calls[3].prompt.contains("outside the supplied evidence"))
        XCTAssertTrue(calls[5].prompt.contains("First part"))
        XCTAssertTrue(calls[5].prompt.contains("Second part"))
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint)) as? [String: Any])
        let notes = try XCTUnwrap(stored["notes"] as? [String: String])
        XCTAssertEqual(try SummaryClaimEvidence.decode(XCTUnwrap(notes["0"]), transcript: source).map(\.text), ["First part"])
    }

    func testFailedChunkRepairResumesWithoutRepeatingValidatedParts() async throws {
        let source = twoPartTranscript()
        let checkpoint = makeCheckpointURL()
        let first = try claims("First part", source: source, quote: "First evidence.")
        let second = try claims("Second part", source: source, segmentIndex: 1, quote: "Second evidence.")
        let invalid = try claims("Bad second part", source: source, segmentIndex: 1, quote: "Not in the transcript")
        let failed = Script([
            .failure(.outputTruncated), .failure(.outputTruncated),
            .value(first), .value(invalid), .value(invalid),
        ])
        do {
            _ = try await generate(script: failed, checkpoint: checkpoint, transcript: source)
            XCTFail("Invalid chunk must not be saved")
        } catch let error as SummaryClaimEvidence.ValidationError {
            XCTAssertEqual(error.reason, .quoteMismatch)
        }
        let resumed = Script([.value(second), .value(first)])
        let result = try await generate(script: resumed, checkpoint: checkpoint, transcript: source)
        let calls = await resumed.recordedCalls()
        XCTAssertTrue(result.contains("First part"))
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[0].prompt.contains("Second evidence."))
        XCTAssertFalse(calls[0].prompt.contains("First evidence."))
    }

    func testSynthesisValidationRepairsBeforeRendering() async throws {
        let script = Script([
            .value(try claims("Verified part")),
            .value(try claims("Invalid synthesis", quote: "Unverified quote")),
            .value(try claims("Repaired synthesis")),
        ])
        let result = try await generate(script: script, checkpoint: makeCheckpointURL(), contextTokens: 7_000)
        let calls = await script.recordedCalls()
        XCTAssertTrue(result.contains("Repaired synthesis"))
        XCTAssertFalse(result.contains("Invalid synthesis"))
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls[2].prompt.contains("Verified part"))
        XCTAssertTrue(calls[2].prompt.contains("quote does not exactly match"))
    }

    func testCancellationDuringRepairStopsWithoutSavingArtifacts() async throws {
        let checkpoint = makeCheckpointURL()
        let script = Script([.value("not JSON"), .cancelled])
        do {
            _ = try await generate(script: script, checkpoint: checkpoint)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Cancellation must bypass repair/fallback and propagate to the pipeline.
        }
        let calls = await script.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
    }

    func testSynthesisCannotIntroduceASourceMissingFromItsPartNotes() async throws {
        let source = twoPartTranscript()
        let provided = try claims("Included in part notes", source: source, quote: "First evidence.")
        let unprovided = try claims("Missing from part notes", source: source, segmentIndex: 1, quote: "Second evidence.")
        let script = Script([.value(provided), .value(unprovided), .value(provided)])
        let result = try await generate(script: script, checkpoint: makeCheckpointURL(), contextTokens: 7_000, transcript: source)
        let calls = await script.recordedCalls()
        XCTAssertTrue(result.contains("Included in part notes"))
        XCTAssertFalse(result.contains("Missing from part notes"))
        XCTAssertEqual(calls.count, 3)
        XCTAssertFalse(calls[1].prompt.contains("\"s2\""))
        XCTAssertTrue(calls[2].prompt.contains("outside the supplied evidence"))
    }

    func testCompactModelCitationsAreResolvedBeforePersistingClaims() async throws {
        let source = sampleTranscript()
        let validated = try SummaryClaimEvidence.decode(claims("Compact citation"), transcript: source)
        let script = Script([.value(try SummaryClaimEvidence.encodeForPrompt(validated, transcript: source))])
        let checkpoint = makeCheckpointURL()
        _ = try await generate(script: script, checkpoint: checkpoint)
        let calls = await script.recordedCalls()
        XCTAssertTrue(calls[0].prompt.contains("[s1]"))
        XCTAssertFalse(calls[0].prompt.contains(source.segmentID(at: 0)))
        let artifact = try JSONDecoder().decode(SummaryClaimEvidence.Artifact.self, from: Data(contentsOf:
            checkpoint.deletingLastPathComponent().appendingPathComponent("summary.claims.partial.json")))
        XCTAssertEqual(artifact.claims.map(\.segmentID), [source.segmentID(at: 0)])
    }

    private func claims(_ text: String, source: Transcript? = nil, segmentIndex: Int = 0,
                        speakerID: String? = nil, quote: String = "topic1", section: String = "TL;DR") throws -> String {
        let evidence = source ?? sampleTranscript()
        return try SummaryClaimEvidence.encode([.init(section: section, text: text,
            speakerID: speakerID ?? Transcript.canonicalSpeakerKey(evidence.segments[segmentIndex].speaker),
            segmentID: evidence.segmentID(at: segmentIndex), quote: quote)])
    }

    private func twoPartTranscript() -> Transcript {
        Transcript(segments: [
            .init(start: 0, end: 1, speaker: "me", text: "First evidence.", confidence: nil),
            .init(start: 2, end: 3, speaker: "me", text: "Second evidence.", confidence: nil),
        ], engine: "test")
    }

    private func generate(
        script: Script,
        checkpoint: URL,
        contextTokens: Int = MainLLMRuntimePolicy.contextTokens,
        transcript: Transcript? = nil
    ) async throws -> String {
        try await MeetingSummaryGenerator.generate(
            transcript: transcript ?? sampleTranscript(),
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
