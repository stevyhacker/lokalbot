import XCTest

/// Drives the real first-run wizard and pins down the privacy contract that
/// day-memory features begin off and remain explicit opt-ins.
final class OnboardingUITests: XCTestCase {
    private var root: URL!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnboardingUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("meetings"),
            withIntermediateDirectories: true)

        let launch = try UITestHarness.launch(
            storageRoot: root,
            suitePrefix: "Onboarding",
            settingsJSON: """
            {
              "menuBarOnly": false,
              "trackingEnabled": false,
              "screenshotsEnabled": false,
              "calendarDetectionEnabled": false,
              "semanticSearchEnabled": false,
              "cotypingEnabled": false,
              "dictationEnabled": false
            }
            """,
            environment: ["LOKALBOT_UI_TEST_WINDOW": "onboarding"])
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: root)
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testWizardExplainsValueAndKeepsDayMemoryOptIn() {
        assertPage(title: "Welcome to LokalBot", step: 1)
        app.buttons["Continue"].click()
        assertPage(title: "Remember. Ask. Write. Act.", step: 2)
        app.buttons["Continue"].click()
        assertPage(title: "Private by default", step: 3)
        app.buttons["Continue"].click()
        assertPage(title: "Remember your day?", step: 4)

        XCTAssertEqual(app.switches.count, 3,
                       "day-memory page should expose its three independent opt-ins")
        XCTAssertTrue(text(containing: "Activity, text, and visual context all start off")
            .exists, "day-memory page did not explain its opt-in defaults")

        // With visual context still off, Screen Recording is intentionally not
        // requested by the permissions step.
        app.buttons["Continue to permissions"].click()
        assertPage(title: "Grant LokalBot access", step: 5)
        XCTAssertFalse(text(containing: "Screen Recording").exists,
                       "onboarding requested Screen Recording before visual opt-in")

        app.buttons["Back"].click()
        assertPage(title: "Remember your day?", step: 4)
        app.switches.element(boundBy: 2).click()
        app.buttons["Continue to permissions"].click()
        assertPage(title: "Grant LokalBot access", step: 5)
        XCTAssertTrue(text(containing: "Screen Recording").waitForExistence(timeout: 5),
                      "visual-context opt-in did not add its required permission")
        XCTAssertTrue(text(containing: "Permission access stays local")
            .waitForExistence(timeout: 5), "permission privacy reassurance missing")
    }

    private func assertPage(title: String, step: Int) {
        XCTAssertTrue(text(containing: title).waitForExistence(timeout: 6),
                      "onboarding page missing: \(title)")
        let progress = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", "Step \(step) of 5")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 4),
                      "onboarding progress did not reach step \(step)")
    }

    private func text(containing fragment: String) -> XCUIElement {
        UITestHarness.staticText(containing: fragment, in: app)
    }
}
