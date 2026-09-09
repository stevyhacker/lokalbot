import XCTest
@testable import LokalBot

/// Opt-in, local-only latency/quality replay. Normal unit/CI runs skip it.
/// The manifest and all transcript/output files stay outside the repository.
final class MeetingNotesReplayTests: XCTestCase {
    private actor Recorder {
        let folder: URL
        var count = 0
        init(folder: URL) { self.folder = folder }
        func save(_ content: String) throws {
            count += 1
            try Data(content.utf8).write(to: folder.appendingPathComponent("model-response-\(count).txt"), options: .atomic)
        }
    }

    private struct RecordingEngine: TextEngine {
        let base: OpenAICompatibleEngine
        let recorder: Recorder
        var displayName: String { base.displayName }
        var accountsForGenerationRequests: Bool { true }
        func tokenCount(_ text: String) async throws -> Int? { try await base.tokenCount(text) }
        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            try await base.generate(system: system, prompt: prompt, context: context)
        }
        func generate(system: String, prompt: String, context: [String], schema: [String: Any],
                      options: TextGenerationOptions) async throws -> String {
            do {
                let result = try await base.generate(system: system, prompt: prompt, context: context, schema: schema, options: options)
                try await recorder.save(result)
                return result
            } catch let truncated as TruncatedStructuredResponse {
                try await recorder.save(truncated.content)
                throw truncated
            }
        }
    }
    private struct Manifest: Decodable {
        var transcript: String
        var output: String
        var endpoint: String
        var tokenFile: String
    }

    func testLocalQwenReplay() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_NOTES_REPLAY_MANIFEST"] else {
            throw XCTSkip("Set LOKALBOT_NOTES_REPLAY_MANIFEST to run the isolated local benchmark.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let endpoint = try XCTUnwrap(URL(string: manifest.endpoint))
        XCTAssertEqual(endpoint.host, "127.0.0.1", "meeting replays must stay local")
        guard endpoint.host == "127.0.0.1" else { return }
        let source = URL(fileURLWithPath: manifest.transcript)
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: source))
        let folder = URL(fileURLWithPath: manifest.output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let token = try String(contentsOf: URL(fileURLWithPath: manifest.tokenFile), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = OpenAICompatibleEngine(baseURL: endpoint, model: "qwen3.5-4b", apiKey: token,
            extraBody: MainLLMRuntimePolicy.requestOverrides(for: "qwen3.5-4b"), chatDialect: .llamaServer)
        let engine = RecordingEngine(base: base, recorder: Recorder(folder: folder))
        let language = SummaryLanguage.resolvedForTranscript(.matchTranscript, transcript: transcript)
        let result = try await MeetingNotesGenerator.generate(transcript: transcript, engine: engine,
            template: .meeting, language: language, context: MeetingNotes.promptContext(in: source.deletingLastPathComponent()),
            contextTokens: MainLLMRuntimePolicy.contextTokens, meetingID: UUID(), folder: folder)
        try SummaryClaimEvidence.commit(transcript: transcript, in: folder)
        try result.outcomes.write(to: folder)
        try Data(result.body.utf8).write(to: folder.appendingPathComponent("summary.md"), options: .atomic)
        // Mechanical source/identity checks supplement manual coverage review.
        let claimsJSON = try SummaryClaimEvidence.encode(result.claims)
        XCTAssertNoThrow(try SummaryClaimEvidence.decode(claimsJSON, transcript: transcript, template: .meeting))
        for action in result.outcomes.actionItems {
            XCTAssertFalse(action.citations.isEmpty)
            XCTAssertTrue(action.citations.allSatisfy { transcript.segmentSourceMap[$0.segmentID] != nil })
            if action.isForUser {
                let owner = try XCTUnwrap(action.attribution?.speakerID)
                XCTAssertEqual(transcript.speakerRoster[owner]?.identity, .user)
                XCTAssertNil(action.attribution?.rejectionReason)
            }
        }
    }
}
