import XCTest

/// Pins down the one-time Meetings welcome card: dismissing it must reveal a
/// useful empty state and the choice must survive a fresh app process.
final class GettingStartedUITests: XCTestCase {
    private var root: URL!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GettingStartedUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("meetings"),
            withIntermediateDirectories: true)

        let launch = try UITestHarness.launch(
            storageRoot: root,
            suitePrefix: "GettingStarted",
            environment: ["LOKALBOT_SHOW_GETTING_STARTED": "1"])
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: root)
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testDismissedCardStaysDismissedAcrossRelaunch() throws {
        UITestHarness.clickSidebar("sidebar.meetings", in: app)
        let dismiss = app.buttons["welcome.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 8), "getting-started card did not appear")
        dismiss.click()

        XCTAssertTrue(UITestHarness.staticText(containing: "No meetings yet", in: app)
            .waitForExistence(timeout: 4), "dismiss did not reveal the Meetings empty state")
        XCTAssertFalse(dismiss.exists, "getting-started card remained visible after dismissal")

        app = try UITestHarness.relaunch(
            storageRoot: root,
            defaultsSuiteName: try XCTUnwrap(defaultsSuiteName))
        UITestHarness.clickSidebar("sidebar.meetings", in: app)

        XCTAssertTrue(UITestHarness.staticText(containing: "No meetings yet", in: app)
            .waitForExistence(timeout: 8), "dismissed state did not survive relaunch")
        XCTAssertFalse(app.buttons["welcome.dismiss"].exists,
                       "getting-started card returned after relaunch")
    }
}
