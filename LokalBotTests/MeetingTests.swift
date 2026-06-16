import XCTest
@testable import Botina

final class MeetingTests: XCTestCase {
    func testDurationLabelForInProgressMeeting() {
        let meeting = Meeting(
            id: UUID(),
            title: "Planning",
            appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: nil,
            relativePath: "meetings/2026/06/16-planning"
        )

        XCTAssertEqual(meeting.durationLabel, "in progress")
    }

    func testDurationLabelForMinutes() {
        let meeting = Meeting(
            id: UUID(),
            title: "Planning",
            appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 90),
            relativePath: "meetings/2026/06/16-planning"
        )

        XCTAssertEqual(meeting.durationLabel, "1 min")
    }

    func testDurationLabelForHoursAndMinutes() {
        let meeting = Meeting(
            id: UUID(),
            title: "Planning",
            appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 7_500),
            relativePath: "meetings/2026/06/16-planning"
        )

        XCTAssertEqual(meeting.durationLabel, "2h 5m")
    }
}
