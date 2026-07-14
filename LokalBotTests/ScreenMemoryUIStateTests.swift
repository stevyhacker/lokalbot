import XCTest
@testable import LokalBot

final class ScreenMemoryUIStateTests: XCTestCase {
    func testSevenDayScopeIncludesTodayAndSixPreviousCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Podgorica"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-14T12:00:00+02:00"))
        let interval = try XCTUnwrap(
            ScreenSearchDateScope.sevenDays.interval(now: now, calendar: calendar))

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: interval.start),
                       DateComponents(year: 2026, month: 7, day: 8))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: interval.end),
                       DateComponents(year: 2026, month: 7, day: 15))
    }

    func testPinnedScreenContextCarriesExactCitationAndCleansFTSMarkers() {
        let hit = ActivityStore.OCRHit(
            snapshotID: 42,
            ts: Date(timeIntervalSince1970: 1_700_000_000),
            app: "Safari",
            windowTitle: "Refund docs",
            snippet: "Click «Issue refund»\nthen confirm")

        let prompt = ScreenAskContext.prompt(
            question: "What should I click?", contexts: [ScreenAskContext(hit: hit)])

        XCTAssertTrue(prompt.contains("[screen:42]"))
        XCTAssertTrue(prompt.contains("Safari — Refund docs"))
        XCTAssertTrue(prompt.contains("Click Issue refund then confirm"))
        XCTAssertTrue(prompt.hasSuffix("Question: What should I click?"))
    }

    func testNoPinnedContextLeavesQuestionUnchanged() {
        XCTAssertEqual(ScreenAskContext.prompt(question: "Hello", contexts: []), "Hello")
    }
}
