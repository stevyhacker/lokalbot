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
