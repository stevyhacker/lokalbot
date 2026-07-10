import XCTest
@testable import LokalBot

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

    func testLanguageDetectionTextExcludesMarkdownAndSpeakerLabels() {
        let transcript = Transcript(
            segments: [
                .init(start: 65, end: 66, speaker: "me",
                      text: " We should ship the analytics summary. ",
                      confidence: nil),
                .init(start: 67, end: 68, speaker: "them 1",
                      text: "<|en|> Then follow up tomorrow.",
                      confidence: nil),
            ],
            engine: "test",
            speakerAliases: ["them 1": "Ana"]
        )

        XCTAssertEqual(transcript.languageDetectionText,
                       "We should ship the analytics summary. Then follow up tomorrow.")
        XCTAssertFalse(transcript.languageDetectionText.contains("[00:"))
        XCTAssertFalse(transcript.languageDetectionText.contains("Ana"))
        XCTAssertFalse(transcript.languageDetectionText.contains("**"))
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

    func testDisplayIndexCachesNormalizedVisibleTextAndSpeakerPresentation() {
        let transcript = Transcript(
            segments: [
                .init(start: 3, end: 4, speaker: "them 1",
                      text: "<|0.00|>  Ship   it. <|1.00|>", confidence: nil),
                .init(start: 4, end: 5, speaker: "me",
                      text: "<|0.00|>...<|1.00|>", confidence: nil),
                .init(start: 1, end: 2, speaker: " me ",
                      text: " Earlier update ", confidence: nil),
            ],
            engine: "test",
            speakerAliases: ["them 1": "Ana"])

        let display = Transcript.DisplayIndex(transcript: transcript)

        XCTAssertEqual(display.segments.map(\.id), [0, 2],
                       "Filtering must retain source-order identities")
        XCTAssertEqual(display.segments.map(\.text), ["Ship it.", "Earlier update"])
        XCTAssertEqual(display.segments.map(\.speakerLabel), ["Ana", "Me"])
        XCTAssertEqual(display.segments.map(\.hasSpeakerAlias), [true, false])
        XCTAssertEqual(display.segments.map(\.speakerKey), ["them 1", "me"])
    }

    func testDisplayIndexFindsActiveOverlapsWithoutReorderingRows() {
        let transcript = Transcript(
            segments: [
                .init(start: 5, end: 6, speaker: "them", text: "Short overlap", confidence: nil),
                .init(start: 0, end: 10, speaker: "me", text: "Long segment", confidence: nil),
                .init(start: 11, end: 11.1, speaker: "them", text: "Brief", confidence: nil),
            ],
            engine: "test")
        let display = Transcript.DisplayIndex(transcript: transcript)

        XCTAssertEqual(display.segments.map(\.id), [0, 1, 2])
        XCTAssertEqual(display.activeSegmentIDs(at: -0.1), [])
        XCTAssertEqual(display.activeSegmentIDs(at: 5.5), [0, 1])
        XCTAssertEqual(display.activeSegmentIDs(at: 7), [1],
                       "An expired newer segment must not hide an older overlap")
        XCTAssertEqual(display.activeSegmentIDs(at: 10), [],
                       "Segment ends remain exclusive")
        XCTAssertEqual(display.activeSegmentIDs(at: 11.4), [2],
                       "Existing half-second minimum highlight remains intact")
        XCTAssertEqual(display.activeSegmentIDs(at: 11.5), [])
    }
}
