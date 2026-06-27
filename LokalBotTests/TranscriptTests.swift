import XCTest
@testable import LokalBotV3

final class TranscriptTests: XCTestCase {
    func testTimestampFormattingUsesHourMinuteSecondFormat() {
        XCTAssertEqual(Transcript.stamp(0), "00:00:00")
        XCTAssertEqual(Transcript.stamp(65), "00:01:05")
        XCTAssertEqual(Transcript.stamp(3_661), "01:01:01")
    }

    func testMarkdownRenderingIncludesSpeakerAndTimestamp() {
        let transcript = Transcript(
            segments: [
                .init(start: 65, end: 70, speaker: "me", text: "Ship it.", confidence: 0.9),
            ],
            engine: "test"
        )

        XCTAssertEqual(transcript.markdown, "**[00:01:05] Me:** Ship it.")
    }

    func testDecodesLegacyTranscriptWithoutSpeakerAliases() throws {
        let json = #"""
        {
          "engine" : "test",
          "segments" : [
            { "start" : 1, "end" : 2, "speaker" : "them 1", "text" : "Hello" }
          ]
        }
        """#

        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))

        XCTAssertTrue(transcript.speakerAliases.isEmpty)
        XCTAssertEqual(transcript.displaySpeaker(for: "them 1"), "Them 1")
    }

    func testMarkdownRenderingUsesSpeakerAliases() {
        let transcript = Transcript(
            segments: [
                .init(start: 65, end: 70, speaker: "them 1", text: "Ship it.", confidence: 0.9),
            ],
            engine: "test",
            speakerAliases: ["them 1": "Ana"]
        )

        XCTAssertEqual(transcript.markdown, "**[00:01:05] Ana:** Ship it.")
    }

    func testSpeakerAliasCanBeSetAndReset() {
        var transcript = Transcript(
            segments: [
                .init(start: 65, end: 70, speaker: "them 1", text: "Ship it.", confidence: 0.9),
            ],
            engine: "test"
        )

        transcript.setSpeakerAlias("  Ana   Maria  ", for: "Them 1")
        XCTAssertEqual(transcript.displaySpeaker(for: "them 1"), "Ana Maria")

        transcript.setSpeakerAlias("Them 1", for: "them 1")
        XCTAssertNil(transcript.speakerAlias(for: "them 1"))
    }

    func testNormalizedTextStripsWhisperControlTokens() {
        let raw = "<|startoftranscript|><|en|><|transcribe|><|0.00|> Ship it.<|2.00|><|endoftext|>"

        XCTAssertEqual(Transcript.normalizedText(raw), "Ship it.")
    }

    func testNormalizedTextDropsPunctuationOnlySegments() {
        XCTAssertEqual(Transcript.normalizedText("<|0.00|>.<|2.00|>"), "")
    }

    func testMarkdownRenderingNormalizesSegmentText() {
        let transcript = Transcript(
            segments: [
                .init(start: 1, end: 2, speaker: "me",
                      text: "<|startoftranscript|><|en|><|transcribe|><|0.00|> Ship it.<|2.00|>",
                      confidence: nil),
            ],
            engine: "test"
        )

        XCTAssertEqual(transcript.markdown, "**[00:00:01] Me:** Ship it.")
    }

    func testMergedTranscriptSortsSegmentsByTimestamp() {
        let first = Transcript(
            segments: [.init(start: 30, end: 35, speaker: "them", text: "Second", confidence: nil)],
            engine: "system"
        )
        let second = Transcript(
            segments: [.init(start: 10, end: 15, speaker: "me", text: "First", confidence: nil)],
            engine: "mic"
        )

        let merged = Transcript.merged([first, second])

        XCTAssertEqual(merged.segments.map(\.text), ["First", "Second"])
        XCTAssertEqual(merged.engine, "system")
    }
}
