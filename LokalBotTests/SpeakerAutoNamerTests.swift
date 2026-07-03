import XCTest
@testable import LokalBot

/// Automatic speaker naming from calendar attendees: only the unambiguous
/// single-speaker/single-attendee case gets an alias; everything else is left
/// exactly as diarization produced it.
final class SpeakerAutoNamerTests: XCTestCase {

    private func transcript(speakers: [String]) -> Transcript {
        Transcript(segments: speakers.enumerated().map { index, speaker in
            .init(start: Double(index * 10), end: Double(index * 10 + 5),
                  speaker: speaker, text: "Segment \(index).", confidence: nil)
        }, engine: "test")
    }

    func testSingleRemoteSpeakerWithOneAttendeeGetsNamed() {
        let named = SpeakerAutoNamer.applyingAliases(
            to: transcript(speakers: ["me", "them", "me", "them"]),
            participantNames: ["Ana Petrović"])
        XCTAssertEqual(named.speakerAliases["them"], "Ana Petrović")
        XCTAssertEqual(named.displaySpeaker(for: "them"), "Ana Petrović")
        // Raw labels stay untouched — only the alias layer changes.
        XCTAssertTrue(named.segments.allSatisfy { $0.speaker == "me" || $0.speaker == "them" })
    }

    func testMultipleAttendeesAreSkipped() {
        let named = SpeakerAutoNamer.applyingAliases(
            to: transcript(speakers: ["me", "them"]),
            participantNames: ["Ana Petrović", "Marko Marković"])
        XCTAssertTrue(named.speakerAliases.isEmpty)
    }

    func testNumberedSpeakersAreSkipped() {
        let named = SpeakerAutoNamer.applyingAliases(
            to: transcript(speakers: ["me", "them 1", "them 2"]),
            participantNames: ["Ana Petrović"])
        XCTAssertTrue(named.speakerAliases.isEmpty)
    }

    func testExistingAliasIsPreserved() {
        var existing = transcript(speakers: ["me", "them"])
        existing.setSpeakerAlias("Hand-Renamed", for: "them")
        let named = SpeakerAutoNamer.applyingAliases(
            to: existing, participantNames: ["Ana Petrović"])
        XCTAssertEqual(named.speakerAliases["them"], "Hand-Renamed")
    }

    func testNoHintsOrBlankHintsAreSkipped() {
        let base = transcript(speakers: ["me", "them"])
        XCTAssertTrue(SpeakerAutoNamer.applyingAliases(
            to: base, participantNames: []).speakerAliases.isEmpty)
        XCTAssertTrue(SpeakerAutoNamer.applyingAliases(
            to: base, participantNames: ["   "]).speakerAliases.isEmpty)
    }

    func testMicOnlyTranscriptWithoutRemoteSpeakerIsSkipped() {
        let named = SpeakerAutoNamer.applyingAliases(
            to: transcript(speakers: ["me", "me"]),
            participantNames: ["Ana Petrović"])
        XCTAssertTrue(named.speakerAliases.isEmpty)
    }
}
