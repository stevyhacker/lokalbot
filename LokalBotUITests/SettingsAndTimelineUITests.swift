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
        XCTAssertTrue(app.outlines["meeting.list"].waitForExistence(timeout: 10),
                      "main window never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testPermissionRepairPaneRendersCorePermissions() {
        UITestHarness.clickSidebar("sidebar.settings", in: app)

        XCTAssertTrue(UITestHarness.staticText(containing: "Grant three permissions", in: app)
            .waitForExistence(timeout: 6), "permission repair pane missing")
        XCTAssertTrue(UITestHarness.staticText(containing: "Microphone", in: app).exists,
                      "microphone permission row missing")
        XCTAssertTrue(UITestHarness.staticText(containing: "Screen & System Audio Recording", in: app).exists,
                      "screen/system-audio permission row missing")
        XCTAssertTrue(UITestHarness.staticText(containing: "Accessibility", in: app).exists,
                      "accessibility permission row missing")
        XCTAssertTrue(app.buttons["Relaunch LokalBot"].exists,
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
        XCTAssertTrue(app.outlines["meeting.list"].waitForExistence(timeout: 10),
                      "main window never rendered after relaunch")
    }
}

final class TimelineEmptyStateUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant(includeActivity: false)
        let launch = try UITestHarness.launch(storageRoot: fixture.root, suitePrefix: "TimelineEmpty")
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        XCTAssertTrue(app.outlines["meeting.list"].waitForExistence(timeout: 10),
                      "main window never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testTimelineEmptyStateDoesNotRenderPopulatedTrackOrInspector() {
        UITestHarness.clickSidebar("sidebar.timeline", in: app)

        XCTAssertTrue(UITestHarness.staticText(containing: "No activity recorded", in: app)
            .waitForExistence(timeout: 6), "empty timeline message missing")
        XCTAssertFalse(app.descendants(matching: .any)["timeline.track"].exists,
                       "activity track should not render without activity blocks")
        XCTAssertFalse(app.descendants(matching: .any)["timeline.inspector"].exists,
                       "inspector should not render without activity blocks")
    }
}
