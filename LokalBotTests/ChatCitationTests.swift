import XCTest
@testable import LokalBot

/// Citation-marker parsing: `[meeting:ID@HH:MM:SS]` markers the assistant
/// emits are stripped from display text and surfaced as deep-linkable
/// citations, while ordinary bracketed text passes through untouched.
final class ChatCitationTests: XCTestCase {

    func testExtractTimedMarker() {
        let (display, citations) = ChatCitationParser.extract(
            "You agreed to ship Friday [meeting:a1b2c3d4@00:14:32].")
        XCTAssertEqual(display, "You agreed to ship Friday.")
        XCTAssertEqual(citations, [ChatCitation(meetingID: "a1b2c3d4", seconds: 872)])
        XCTAssertEqual(citations.first?.stampText, "00:14:32")
    }

    func testExtractUntimedAndShortStampMarkers() {
        let (display, citations) = ChatCitationParser.extract(
            "Decided in kickoff [meeting:a1b2c3d4] and revisited [meeting:ffee9900@7:05].")
        XCTAssertEqual(display, "Decided in kickoff and revisited.")
        XCTAssertEqual(citations, [
            ChatCitation(meetingID: "a1b2c3d4", seconds: nil),
            ChatCitation(meetingID: "ffee9900", seconds: 425),
        ])
    }

    func testDuplicateMarkersDedupe() {
        let (_, citations) = ChatCitationParser.extract(
            "A [meeting:a1b2c3d4@0:30]. B [meeting:a1b2c3d4@0:30]. C [meeting:a1b2c3d4@0:45].")
        XCTAssertEqual(citations.count, 2)
    }

    func testTextWithoutMarkersPassesThrough() {
        let text = "No citations here — [link](https://example.com) stays, and [meeting notes] too."
        let (display, citations) = ChatCitationParser.extract(text)
        XCTAssertEqual(display, text)
        XCTAssertTrue(citations.isEmpty)
    }

    func testMalformedMarkersAreLeftInPlace() {
        let text = "Odd [meeting:ab] and [meeting:] stay."      // id too short / missing
        let (display, citations) = ChatCitationParser.extract(text)
        XCTAssertEqual(display, text)
        XCTAssertTrue(citations.isEmpty)
    }

    func testSecondsFromStampForms() {
        XCTAssertEqual(ChatCitationParser.seconds(from: "1:23"), 83)
        XCTAssertEqual(ChatCitationParser.seconds(from: "00:14:32"), 872)
        XCTAssertEqual(ChatCitationParser.seconds(from: "2:00:05"), 7_205)
        XCTAssertNil(ChatCitationParser.seconds(from: "1:99"))
        XCTAssertNil(ChatCitationParser.seconds(from: "12"))
    }
}
