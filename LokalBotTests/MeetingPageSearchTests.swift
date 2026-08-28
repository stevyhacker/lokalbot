import XCTest
@testable import LokalBot

final class MeetingPageSearchTests: XCTestCase {
    func testMatchesNotesSummaryAndTranscriptInReadingOrder() {
        let transcript = Transcript(
            segments: [
                .init(start: 0, end: 4, speaker: "me", text: "A cafe transcript hit."),
                .init(start: 4, end: 8, speaker: "them", text: "Nothing relevant."),
            ],
            engine: "fixture")

        let matches = MeetingPageSearch.matches(
            query: "cafe",
            notesText: "Café note",
            summaryText: "CAFE appears once, then café appears again.",
            transcript: transcript)

        XCTAssertEqual(matches, [
            .init(location: .notes, occurrenceIndex: 0),
            .init(location: .summary, occurrenceIndex: 0),
            .init(location: .summary, occurrenceIndex: 1),
            .init(location: .transcript(segmentIndex: 0), occurrenceIndex: 0),
        ])
    }

    func testWhitespaceOnlyQueryHasNoMatches() {
        let matches = MeetingPageSearch.matches(
            query: "  \n ",
            notesText: "Text",
            summaryText: "Text",
            transcript: nil)

        XCTAssertTrue(matches.isEmpty)
    }

    func testRangesAreCaseInsensitiveAndNonOverlapping() {
        let text = "Redis REDIS redis"
        let ranges = MeetingPageSearch.ranges(in: text, query: "redis")

        XCTAssertEqual(ranges.map { String(text[$0]) }, ["Redis", "REDIS", "redis"])
    }
}
