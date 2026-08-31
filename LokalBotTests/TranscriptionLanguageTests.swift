import XCTest
@testable import LokalBot

final class TranscriptionLanguageTests: XCTestCase {
    func testTranscriptionPromptTrimsWhitespaceAndDropsEmptyValues() {
        XCTAssertEqual(
            TranscriptionPrompt.normalized("  LokalBot, QVAC  \n"),
            "LokalBot, QVAC")
        XCTAssertNil(TranscriptionPrompt.normalized(" \n\t "))
        XCTAssertNil(TranscriptionPrompt.normalized(nil))
    }

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

    func testMatchTranscriptIsNotHijackedByOneForeignOpeningSegment() {
        let opening = Transcript.Segment(
            start: 0,
            end: 3,
            speaker: "me",
            text: "Das ist eine kurze fehlerhafte deutsche Transkription am Anfang.",
            confidence: nil)
        let english = [
            "We reviewed the launch plan and agreed to keep the rollout focused on reliability and customer feedback.",
            "The engineering team explained the architecture, accounting changes, and validation strategy for the next release.",
            "Everyone discussed the remaining tests, ownership, documentation, and the timeline for publishing the completed work.",
            "The meeting continued in English with detailed decisions, open questions, and concrete follow-up tasks for each participant.",
            "We closed by confirming the next milestone and scheduling another review after the implementation was ready.",
        ]
        let englishSegments: [Transcript.Segment] = (0..<20).map { index in
            let start = Double(index + 1) * 4
            return Transcript.Segment(
                start: start,
                end: start + 4,
                speaker: "them",
                text: english[index % english.count],
                confidence: nil)
        }
        let segments = [opening] + englishSegments
        let transcript = Transcript(segments: segments, engine: "test")

        XCTAssertEqual(
            SummaryLanguage.resolvedForTranscript(.matchTranscript, transcript: transcript),
            .en)
    }

    func testDistributedDetectionStillSelectsDominantGerman() {
        let transcript = Transcript(
            segments: (0..<12).map { index in
                .init(
                    start: Double(index) * 4,
                    end: Double(index + 1) * 4,
                    speaker: "them",
                    text: "Wir besprechen den Projektplan, die offenen Aufgaben und den Termin für die nächste Veröffentlichung.",
                    confidence: nil)
            },
            engine: "test")

        XCTAssertEqual(
            SummaryLanguage.resolvedForTranscript(.matchTranscript, transcript: transcript),
            .de)
    }
}

final class SummaryPromptActionabilityTests: XCTestCase {
    func testFixedLanguageKeepsCanonicalMarkdownHeadings() {
        let system = PromptTemplates.systemPrompt(
            for: .meeting,
            summaryLanguage: .de)
        let user = PromptTemplates.userPrompt(
            transcript: "**[00:00:01] Me:** Ich sende den Entwurf.",
            template: .meeting,
            summaryLanguage: .de)

        for prompt in [system, user] {
            XCTAssertTrue(prompt.contains("do not translate"), prompt)
            XCTAssertTrue(prompt.contains("Markdown"), prompt)
        }
    }

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
            XCTAssertTrue(prompt.contains("first person"), template.rawValue)
            XCTAssertTrue(prompt.contains("Me will"), template.rawValue)
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

    func testMeetingPromptsKeepTentativeTermsAndActionsOutOfDecisions() {
        let direct = PromptTemplates.systemPrompt(for: .meeting)
        let chunk = PromptTemplates.chunkExtractionSystem()

        for prompt in [direct, chunk] {
            XCTAssertTrue(prompt.contains("explicitly settled"), prompt)
            XCTAssertTrue(prompt.contains("Tentative terms"), prompt)
            XCTAssertTrue(prompt.contains("never duplicate"), prompt)
            XCTAssertTrue(prompt.contains("## Open questions"), prompt)
        }
    }
}
