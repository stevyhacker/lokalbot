import XCTest
@testable import LokalBot

final class TimelineWorkSessionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_760_000_000)

    private func block(
        _ id: Int64,
        app: String,
        title: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> ActivityBlock {
        ActivityBlock(
            id: id,
            app: app,
            title: title,
            start: base.addingTimeInterval(start),
            end: base.addingTimeInterval(end))
    }

    func testShortGapsCollapseIntoOneWorkSession() {
        let sessions = TimelineWorkSession.sessions(from: [
            block(1, app: "Xcode", title: "CaptureView.swift", start: 0, end: 60),
            block(2, app: "Safari", title: "Pull request #42", start: 120, end: 180),
            block(3, app: "Slack", title: "#engineering", start: 600, end: 660),
        ])

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].blocks.map(\.id), [1, 2])
        XCTAssertEqual(sessions[0].activeDuration, 120)
        XCTAssertEqual(sessions[0].contextSwitchCount, 1)
        XCTAssertEqual(sessions[1].blocks.map(\.id), [3])
    }

    func testSystemOnlyActivityDoesNotBecomeAWorkSession() {
        let sessions = TimelineWorkSession.sessions(from: [
            block(1, app: "loginwindow", title: "Login Window", start: 0, end: 600),
            block(2, app: "WindowServer", title: "WindowServer", start: 600, end: 660),
            block(3, app: "Xcode", title: "TimelineWorkSession.swift", start: 900, end: 1_500),
        ])

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].blocks.map(\.id), [3])
        XCTAssertEqual(sessions[0].title, "TimelineWorkSession.swift")
    }

    func testOverlappingBlocksDoNotDoubleCountActiveTime() {
        let sessions = TimelineWorkSession.sessions(from: [
            block(1, app: "Xcode", title: "Timeline", start: 0, end: 600),
            block(2, app: "Safari", title: "Design reference", start: 300, end: 900),
        ])

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].activeDuration, 900)
        XCTAssertEqual(sessions[0].apps, ["Xcode", "Safari"])
    }

    func testPrimaryAppAndTitleUseGroundedDuration() {
        let sessions = TimelineWorkSession.sessions(from: [
            block(1, app: "Safari", title: "New Tab", start: 0, end: 60),
            block(2, app: "Xcode", title: "CaptureView.swift", start: 60, end: 660),
            block(3, app: "Xcode", title: "Tests", start: 660, end: 780),
        ])

        XCTAssertEqual(sessions.first?.primaryApp, "Xcode")
        XCTAssertEqual(sessions.first?.title, "CaptureView.swift")
        XCTAssertEqual(sessions.first?.notableTitles.first, "CaptureView.swift")
    }

    func testSessionTitleStripsBrowserChromeSuffixes() {
        let sessions = TimelineWorkSession.sessions(from: [
            block(1, app: "Google Chrome",
                  title: "Kaya beach Ulcinj bilježi odličnu posjećenost - YouTube - Audio playing - Google Chrome - Stevan",
                  start: 0, end: 600),
        ])

        XCTAssertEqual(sessions.first?.title,
                       "Kaya beach Ulcinj bilježi odličnu posjećenost - YouTube")
    }

    func testStrippingBrowserChromeHandlesFirefoxAndPlainTitles() {
        XCTAssertEqual(
            TimelineWorkSession.strippingBrowserChrome("Docs — Mozilla Firefox"),
            "Docs")
        XCTAssertEqual(
            TimelineWorkSession.strippingBrowserChrome("Home / X - Google Chrome - Stevan"),
            "Home / X")
        XCTAssertEqual(
            TimelineWorkSession.strippingBrowserChrome("Meeting notes - draft two"),
            "Meeting notes - draft two",
            "titles without marker segments pass through untouched")
        XCTAssertEqual(
            TimelineWorkSession.strippingBrowserChrome("Google Chrome"),
            "Google Chrome",
            "a bare browser name is left for the generic-title filter")
    }

    func testDayItemsInterleaveSessionsAndMeetings() {
        let session = TimelineWorkSession.sessions(from: [
            block(1, app: "Xcode", title: "CaptureView.swift", start: 0, end: 600),
        ]).first!
        let meeting = Meeting(
            id: UUID(),
            title: "Design review",
            appName: "Zoom",
            startedAt: base.addingTimeInterval(900),
            endedAt: base.addingTimeInterval(1_500),
            relativePath: "meetings/design-review")

        let items = TimelineDayItem.items(
            sessions: [session], meetings: [meeting], now: base.addingTimeInterval(2_000))

        XCTAssertEqual(items.count, 2)
        if case .work = items[0] {} else { XCTFail("work session should be first") }
        if case .meeting = items[1] {} else { XCTFail("meeting should be second") }
    }
}
