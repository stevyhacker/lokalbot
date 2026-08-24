import XCTest
@testable import LokalBot

/// Speaker bleed: with the user on speakers rather than headphones, the remote
/// voice reaches the microphone too and is transcribed a second time as `me`.
/// The filter must remove those echoes without touching a real reply — the
/// separating signal is timing, since an echo is simultaneous with its source
/// while a person repeating something speaks afterwards.
final class SpeakerBleedFilterTests: XCTestCase {

    private func segment(_ speaker: String, _ start: TimeInterval, _ end: TimeInterval,
                         _ text: String) -> Transcript.Segment {
        Transcript.Segment(start: start, end: end, speaker: speaker, text: text, confidence: nil)
    }

    private func transcript(_ segments: [Transcript.Segment]) -> Transcript {
        Transcript(segments: segments, engine: "test")
    }

    /// Verbatim from a real Teams test call recorded on built-in speakers: the
    /// bot's prompt appears once as `them` and once as `me`, the latter with the
    /// leading-punctuation artifact ASR tends to add to clipped echo.
    func testRemovesRealWorldSpeakerBleed() {
        let prompt = "Wenn Sie mit der Qualität der Nachricht zufrieden sind, haben Sie Teams "
            + "richtig konfiguriert. Wenn nicht, überprüfen Sie die Einstellung Ihres Gerätes "
            + "und versuchen Sie es erneut"
        let input = transcript([
            segment("me", 1.0, 4.0, "1, 2, 5, 5"),
            segment("me", 5.0, 17.0, ". " + prompt + "."),
            segment("them", 5.0, 17.0, prompt),
        ])

        let result = SpeakerBleedFilter.filter(input)

        XCTAssertEqual(result.removedSegments, 1)
        XCTAssertEqual(result.transcript.segments.count, 2)
        XCTAssertEqual(result.transcript.segments.map(\.speaker), ["me", "them"])
        // The user's own words survive.
        XCTAssertEqual(result.transcript.segments.first?.text, "1, 2, 5, 5")
    }

    /// The case the filter must never break: agreeing by repeating what was
    /// just said. Same words, but *after* the remote turn rather than during it.
    /// The common shape on a real call: the mic segment opens with echo of the
    /// remote turn and continues with the user's own words. Dropping it loses
    /// real speech, keeping it doubles the remote voice — only the echoed part
    /// may go.
    func testTrimsEchoedOpeningAndKeepsTheUsersOwnWords() {
        let input = transcript([
            segment("them", 10.0, 20.0,
                    "aber ich weiß nicht ob das für heute angedacht war"),
            segment("me", 11.0, 22.0,
                    "aber ich weiß nicht ob das für heute angedacht war. "
                        + "Das sollte mit denen abgestimmt sein die gefehlt haben"),
        ])

        let result = SpeakerBleedFilter.filter(input)

        XCTAssertEqual(result.removedSegments, 0)
        XCTAssertEqual(result.trimmedSegments, 1)
        XCTAssertEqual(result.transcript.segments.count, 2)
        XCTAssertEqual(result.transcript.segments.first(where: { $0.speaker == "me" })?.text,
                       "Das sollte mit denen abgestimmt sein die gefehlt haben")
    }

    /// Echo at the tail is the mirror case and must trim the same way.
    func testTrimsEchoedEnding() {
        let input = transcript([
            segment("me", 5.0, 12.0,
                    "das kann ich noch nicht sagen, wir verschieben das Release auf Donnerstag"),
            segment("them", 6.0, 12.0, "wir verschieben das Release auf Donnerstag"),
        ])

        let result = SpeakerBleedFilter.filter(input)

        XCTAssertEqual(result.trimmedSegments, 1)
        XCTAssertEqual(result.transcript.segments.first?.text, "das kann ich noch nicht sagen")
    }

    /// Two independent ASR passes over different audio spell the same word
    /// differently. Exact word equality missed most real echo, so a single
    /// edit still counts as the same word.
    func testMatchesWordsTheTwoTracksTranscribedDifferently() {
        XCTAssertTrue(SpeakerBleedFilter.wordsMatch("wim", "bim"))
        XCTAssertTrue(SpeakerBleedFilter.wordsMatch("nachmittags", "nachmittag"))
        XCTAssertFalse(SpeakerBleedFilter.wordsMatch("und", "an"))
        XCTAssertFalse(SpeakerBleedFilter.wordsMatch("budget", "termin"))
    }

    /// Echo in the middle would mean the user spoke both before and after it;
    /// stitching the halves together would invent a sentence neither said.
    func testKeepsSegmentWhoseSharedRunSitsInTheMiddle() {
        let input = transcript([
            segment("them", 0.0, 10.0, "auf nächsten Donnerstag verschoben"),
            segment("me", 0.0, 10.0,
                    "ich hatte das anders verstanden auf nächsten Donnerstag verschoben "
                        + "steht so aber nicht im Protokoll drin"),
        ])

        let result = SpeakerBleedFilter.filter(input)

        XCTAssertEqual(result.trimmedSegments, 0)
        XCTAssertEqual(result.removedSegments, 0)
    }

    func testLongestSharedRunReportsItsPositionInTheLeftHandSide() {
        let run = SpeakerBleedFilter.longestSharedRun(
            ["also", "wir", "treffen", "uns", "am", "montag"],
            ["wir", "treffen", "uns", "später"])

        XCTAssertEqual(run, .init(length: 3, start: 1, end: 4))
    }

    func testKeepsGenuineRepetitionThatFollowsTheRemoteTurn() {
        let line = "wir verschieben das Release auf nächsten Donnerstag"
        let input = transcript([
            segment("them", 10.0, 14.0, line),
            segment("me", 14.5, 18.0, line + ", genau"),
        ])

        let result = SpeakerBleedFilter.filter(input)

        XCTAssertEqual(result.removedSegments, 0)
        XCTAssertEqual(result.transcript.segments.count, 2)
    }

    /// Short generic utterances are too common to judge by wording, so they are
    /// never removed even when they overlap.
    func testKeepsShortOverlappingAcknowledgements() {
        let input = transcript([
            segment("them", 3.0, 6.0, "ja genau"),
            segment("me", 3.2, 5.8, "ja genau"),
        ])

        let result = SpeakerBleedFilter.filter(input)

        XCTAssertEqual(result.removedSegments, 0)
    }

    /// Overlapping in time but saying something different — both people talking
    /// at once — must survive.
    func testKeepsSimultaneousButDifferentSpeech() {
        let input = transcript([
            segment("them", 20.0, 26.0,
                    "ich schicke dir die Auswertung nachher noch per Mail zu"),
            segment("me", 20.5, 25.0,
                    "können wir den Termin am Freitag um eine Stunde vorziehen"),
        ])

        let result = SpeakerBleedFilter.filter(input)

        XCTAssertEqual(result.removedSegments, 0)
    }

    /// A mic-only recording (no system track) must pass through untouched —
    /// with nothing to compare against, nothing can be an echo.
    func testMicOnlyTranscriptIsUnchanged() {
        let input = transcript([
            segment("me", 0.0, 4.0, "das hier ist eine ganz normale Aufnahme ohne Gegenstelle"),
            segment("me", 4.0, 8.0, "das hier ist eine ganz normale Aufnahme ohne Gegenstelle"),
        ])

        let result = SpeakerBleedFilter.filter(input)

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments.count, 2)
    }

    /// Only the microphone side is ever dropped: the system track is the clean
    /// source of the remote voice and must survive intact.
    func testNeverRemovesTheRemoteTrack() {
        let line = "das Protokoll liegt im geteilten Ordner bereit für alle"
        let input = transcript([
            segment("me", 2.0, 8.0, line),
            segment("them", 2.0, 8.0, line),
        ])

        let result = SpeakerBleedFilter.filter(input)

        XCTAssertEqual(result.transcript.segments.map(\.speaker), ["them"])
    }

    func testTimeOverlapIsMeasuredAgainstTheShorterSegment() {
        let long = segment("them", 0.0, 20.0, "x")
        let short = segment("me", 9.0, 11.0, "x")
        XCTAssertEqual(SpeakerBleedFilter.timeOverlap(short, long), 1.0, accuracy: 0.001)

        let disjoint = segment("me", 30.0, 32.0, "x")
        XCTAssertEqual(SpeakerBleedFilter.timeOverlap(disjoint, long), 0)
    }

    /// ASR clips the start and end of an echo, so the mic side is usually a
    /// fragment of the remote turn rather than a copy of it.
    func testRecognizesAPartiallyCapturedEcho() {
        let full = SpeakerBleedFilter.words(in: "wir treffen uns morgen um zehn im großen Raum")
        let clipped = SpeakerBleedFilter.words(in: "uns morgen um zehn im großen")
        XCTAssertEqual(SpeakerBleedFilter.longestSharedRun(clipped, full).length, clipped.count)

        let unrelated = SpeakerBleedFilter.words(in: "das Budget ist bereits vollständig verplant")
        XCTAssertLessThan(SpeakerBleedFilter.longestSharedRun(unrelated, full).length,
                          SpeakerBleedFilter.minimumRunLength)
    }
}
