import XCTest

final class SettingsUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        let launch = try UITestHarness.launch(storageRoot: fixture.root, suitePrefix: "Settings")
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        // Timeline is the default section; with seeded activity the hour
        // track renders, so wait on it rather than the meeting list.
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"]
            .waitForExistence(timeout: 10), "main window never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testPermissionRepairPaneRendersCorePermissions() {
        UITestHarness.clickSidebar("sidebar.settings", in: app)

        // Gate on the Microphone row, not the "Permissions" section header:
        // Form section headers surface as label-only StaticTexts that live
        // predicate queries never match on macOS, even though failure-time
        // AX hierarchies show them. Row texts are value-carrying and match.
        XCTAssertTrue(UITestHarness.staticText(containing: "Microphone", in: app)
            .waitForExistence(timeout: 6), "microphone permission row missing")
        XCTAssertTrue(UITestHarness.staticText(containing: "Screen Recording", in: app).exists,
                      "screen/system-audio permission row missing")
        XCTAssertTrue(UITestHarness.staticText(containing: "Accessibility", in: app).exists,
                      "accessibility permission row missing")
        XCTAssertTrue(UITestHarness.staticText(containing: "Input Monitoring", in: app).exists,
                      "optional input monitoring row missing")
        XCTAssertTrue(app.buttons["Relaunch"].exists,
                      "relaunch affordance missing")
    }

    func testCalendarDependentOptionsHiddenWhenCalendarDetectionIsOff() {
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings.form"]
            .waitForExistence(timeout: 6), "settings pane did not render")
        UITestHarness.typeInFirstTextField("calendar", in: app)

        XCTAssertTrue(UITestHarness.staticText(containing: "Use calendar to improve detection", in: app)
            .waitForExistence(timeout: 6), "calendar master toggle missing")
        XCTAssertFalse(UITestHarness.staticText(containing: "Use calendar titles for recordings", in: app).exists,
                       "calendar title toggle should be gated while calendar detection is off")
        XCTAssertFalse(UITestHarness.staticText(containing: "Require a calendar match", in: app).exists,
                       "browser strict-mode toggle should be gated while calendar detection is off")
    }

    func testCalendarDependentOptionsRenderWhenSeededOn() throws {
        try relaunch(settingsJSON: """
        {
          "menuBarOnly": false,
          "trackingEnabled": true,
          "screenshotsEnabled": false,
          "calendarDetectionEnabled": true,
          "useCalendarTitles": true,
          "requireCalendarForBrowser": true,
          "semanticSearchEnabled": false,
          "cotypingEnabled": false
        }
        """)

        UITestHarness.clickSidebar("sidebar.settings", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings.form"]
            .waitForExistence(timeout: 6), "settings pane did not render")
        UITestHarness.typeInFirstTextField("calendar", in: app)

        XCTAssertTrue(UITestHarness.staticText(containing: "Use calendar titles for recordings", in: app)
            .waitForExistence(timeout: 6), "calendar title toggle missing when calendar detection is on")
        XCTAssertTrue(UITestHarness.staticText(containing: "Require a calendar match", in: app).exists,
                      "browser strict-mode toggle missing when calendar detection is on")
        XCTAssertTrue(UITestHarness.staticText(containing: "Calendar access", in: app).exists,
                      "calendar access row missing when calendar detection is on")
    }

    private func relaunch(settingsJSON: String) throws {
        app.terminate()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
        let launch = try UITestHarness.launch(
            storageRoot: fixture.root,
            suitePrefix: "Settings",
            settingsJSON: settingsJSON)
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"]
            .waitForExistence(timeout: 10), "main window never rendered after relaunch")
    }
}

/// Timeline against a fixture with no activity blocks — pins the
/// meetings-as-blocks track (meetings alone populate the day track).
final class TimelineWithoutActivityUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant(includeActivity: false)
        let launch = try UITestHarness.launch(storageRoot: fixture.root, suitePrefix: "TimelineWithoutActivity")
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"]
            .waitForExistence(timeout: 10), "main window never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    /// With no activity blocks seeded, the seeded meetings still render as
    /// first-class track blocks (spec §2.2) rather than the empty state,
    /// and the Meetings section shows the grouped list.
    func testTimelineWithoutActivityShowsMeetingBlocks() {
        // Meetings alone populate the day track (meetings-as-blocks).
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"].exists,
                      "day track with meeting blocks missing")
        XCTAssertFalse(UITestHarness.staticText(containing: "No activity recorded", in: app).exists,
                       "empty state shown despite seeded meetings in the track")

        UITestHarness.clickSidebar("sidebar.meetings", in: app)
        XCTAssertTrue(app.outlines["meeting.list"].waitForExistence(timeout: 6),
                      "meeting list did not render in Meetings")
        XCTAssertFalse(app.descendants(matching: .any)["timeline.track"].exists,
                       "activity track should not render in Meetings")
    }
}
