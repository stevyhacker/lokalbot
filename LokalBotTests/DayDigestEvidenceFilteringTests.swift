import XCTest
@testable import LokalBot

final class DayDigestEvidenceFilteringTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var day: Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 4, hour: 12))!
    }

    private func time(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 4, hour: hour, minute: minute))!
    }

    private func block(_ id: Int64, _ hour: Int, _ title: String) -> ActivityBlock {
        ActivityBlock(
            id: id,
            app: id == 2 ? "Safari" : "Xcode",
            title: title,
            start: time(hour),
            end: time(hour, 45))
    }

    private func context(_ id: Int64, _ hour: Int, _ minute: Int,
                         _ text: String, app: String = "Xcode") -> DayScreenContext {
        DayScreenContext(
            snapshotID: id,
            capturedAt: time(hour, minute),
            app: app,
            windowTitle: "Work window",
            text: text)
    }

    func testSummaryEvidenceLeadsWithWorkContentBeforeTraceMetadata() throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 9, "Day Digest implementation")],
            screenContexts: [
                context(11, 9, 10, "Implemented task-first digest extraction."),
            ],
            meetings: [],
            calendar: calendar)

        let material = evidence.summaryChunks().joined(separator: "\n")
        let workHeader = try XCTUnwrap(material.range(of: "WORK CONTENT")).lowerBound
        let workText = try XCTUnwrap(material.range(of: "Implemented task-first")).lowerBound
        let metadata = try XCTUnwrap(
            material.range(of: "LOW-PRIORITY TRACE METADATA")).lowerBound

        XCTAssertLessThan(workHeader, workText)
        XCTAssertLessThan(workText, metadata)
    }

    func testOnlyExactConsecutiveScreenDuplicatesAreCollapsed() {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                ActivityBlock(
                    id: 1, app: "Xcode", title: "Editor",
                    start: time(9), end: time(10)),
            ],
            screenContexts: [
                context(1, 9, 5, "same text"),
                context(2, 9, 6, "same text"),
                context(3, 9, 7, "different text"),
                context(4, 9, 8, "same text"),
            ],
            meetings: [],
            calendar: calendar)

        XCTAssertEqual(evidence.activities.first?.contexts.map(\.snapshotID), [1, 3, 4])
    }

    func testSummaryDropsRecurringAccessibilityChromeButJournalKeepsIt() {
        let chrome = "this button also has an action to zoom the window "
            + "Bookmarks New Tab Back Forward Reload substantive page content"
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 9, "Research")],
            screenContexts: [context(1, 9, 5, chrome, app: "Google Chrome")],
            meetings: [],
            calendar: calendar)

        let summaryMaterial = evidence.summaryChunks().joined(separator: "\n")
        let journal = evidence.renderDocument(summary: "Summary", calendar: calendar)

        XCTAssertFalse(summaryMaterial.localizedCaseInsensitiveContains(
            "this button also has an action to zoom the window"))
        XCTAssertFalse(summaryMaterial.localizedCaseInsensitiveContains(
            "Bookmarks New Tab Back Forward Reload"))
        XCTAssertTrue(summaryMaterial.contains("substantive page content"))
        XCTAssertTrue(journal.contains("this button also has an action to zoom the window"))
        XCTAssertTrue(journal.contains("Bookmarks New Tab Back Forward Reload"))
    }

    func testSummaryOmitsLoginWindowButJournalKeepsIt() {
        let login = ActivityBlock(
            id: 1,
            app: "loginwindow",
            title: "Login Window",
            start: time(8),
            end: time(8, 2))
        let work = ActivityBlock(
            id: 2,
            app: "Xcode",
            title: "DayDigestEvidence.swift",
            start: time(9),
            end: time(9, 45))
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [login, work],
            screenContexts: [],
            meetings: [],
            calendar: calendar)

        let summaryMaterial = evidence.summaryChunks().joined(separator: "\n")
        let journal = evidence.renderDocument(summary: "Summary", calendar: calendar)

        XCTAssertFalse(summaryMaterial.localizedCaseInsensitiveContains("loginwindow"))
        XCTAssertTrue(summaryMaterial.contains("DayDigestEvidence.swift"))
        XCTAssertTrue(journal.localizedCaseInsensitiveContains("loginwindow"))
    }

    func testFreshnessOnlyMarksDigestWhenEvidenceIsNewer() {
        let digest = time(18)
        XCTAssertFalse(DayDigestFreshness.isStale(
            digestModifiedAt: digest,
            latestEvidenceAt: time(17, 59)))
        XCTAssertFalse(DayDigestFreshness.isStale(
            digestModifiedAt: digest,
            latestEvidenceAt: digest))
        XCTAssertTrue(DayDigestFreshness.isStale(
            digestModifiedAt: digest,
            latestEvidenceAt: time(21)))
        XCTAssertFalse(DayDigestFreshness.isStale(
            digestModifiedAt: nil,
            latestEvidenceAt: time(21)))
    }
}
