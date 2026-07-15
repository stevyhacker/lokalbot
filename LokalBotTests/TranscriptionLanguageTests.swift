import XCTest
@testable import LokalBot

final class TranscriptionLanguageTests: XCTestCase {
    func testAutoLanguageHasNoEngineCode() {
        XCTAssertNil(TranscriptionLanguage.auto.code)
    }

    func testConcreteLanguageUsesRawCode() {
        XCTAssertEqual(TranscriptionLanguage.de.code, "de")
    }

    func testLegacyHintMigrationNormalizesKnownCodes() {
        XCTAssertEqual(TranscriptionLanguage.fromLegacyHint(" DE "), .de)
    }

    func testLegacyHintMigrationFallsBackToAutoForUnknownCodes() {
        XCTAssertEqual(TranscriptionLanguage.fromLegacyHint("klingon"), .auto)
        XCTAssertEqual(TranscriptionLanguage.fromLegacyHint(""), .auto)
    }
}

final class SummaryLanguageTests: XCTestCase {
    func testMatchTranscriptDetectsMajorityLanguageFromRawSegmentText() {
        let transcript = Transcript(
            segments: [
                .init(start: 0, end: 4, speaker: "me",
                      text: "We reviewed the onboarding plan and agreed the first release should stay focused on search quality.",
                      confidence: nil),
                .init(start: 5, end: 9, speaker: "me",
                      text: "A few Portuguese words appeared in the call, obrigado and bom dia, but they were not the meeting language.",
                      confidence: nil),
                .init(start: 10, end: 14, speaker: "them",
                      text: "The next action item is to fix the language detection before regenerating summaries.",
                      confidence: nil),
                .init(start: 15, end: 20, speaker: "me",
                      text: "After that, we can rerun the summary and confirm the notes are written in English.",
                      confidence: nil),
            ],
            engine: "test"
        )

        XCTAssertEqual(SummaryLanguage.resolvedForTranscript(.matchTranscript, transcript: transcript), .en)
    }

    func testConcreteSummaryLanguageStillBypassesDetection() {
        let transcript = Transcript(
            segments: [
                .init(start: 0, end: 1, speaker: "me",
                      text: "This meeting is in English.",
                      confidence: nil),
            ],
            engine: "test"
        )

        XCTAssertEqual(SummaryLanguage.resolvedForTranscript(.pt, transcript: transcript), .pt)
    }
}

final class SummaryPromptActionabilityTests: XCTestCase {
    func testEveryNotesTemplateRequiresAnExplicitUserActionabilityPass() {
        for template in NoteTemplate.allCases {
            let prompt = PromptTemplates.systemPrompt(
                for: template,
                userSpeakerLabel: "Stevan")

            XCTAssertTrue(prompt.contains("## Action items"), template.rawValue)
            XCTAssertTrue(prompt.contains("### Me"), template.rawValue)
            XCTAssertTrue(prompt.contains("### Others"), template.rawValue)
            XCTAssertTrue(prompt.contains("commitments made by \"Stevan\""), template.rawValue)
            XCTAssertTrue(prompt.contains("requests or assignments directed to"), template.rawValue)
            XCTAssertTrue(prompt.contains("Write `None`"), template.rawValue)
            XCTAssertTrue(prompt.contains("generic advice"), template.rawValue)
        }
    }

    func testShortAndLongMeetingPromptsIdentifyARenamedUserSpeaker() {
        let short = PromptTemplates.userPrompt(
            transcript: "**[00:00:01] Stevan:** I'll send the draft.",
            template: .meeting,
            userSpeakerLabel: "Stevan")
        let chunk = PromptTemplates.chunkExtractionSystem(userSpeakerLabel: "Stevan")

        XCTAssertTrue(short.contains("speaker labeled \"Stevan\" is this Mac's user"), short)
        XCTAssertTrue(chunk.contains("speaker labeled \"Stevan\" is this Mac's user"), chunk)
        XCTAssertTrue(chunk.contains("requests or assignments directed to \"Stevan\""), chunk)
        XCTAssertTrue(chunk.contains("### Me"), chunk)
        XCTAssertTrue(chunk.contains("### Others"), chunk)
    }
}
