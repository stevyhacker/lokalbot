import XCTest

/// Drives the real first-run wizard and pins down the permission contract for
/// the day-memory layers selected by default.
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
              "trackingEnabled": true,
              "screenshotsEnabled": true,
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

    func testWizardExplainsDayMemoryDefaultsAndPermissionGates() {
        assertPage(title: "Welcome to LokalBot", step: 1)
        app.buttons["Continue"].click()
        assertPage(title: "Remember. Ask. Write. Act.", step: 2)
        app.buttons["Continue"].click()
        assertPage(title: "Private by default", step: 3)
        app.buttons["Continue"].click()
        assertPage(title: "Remember your day?", step: 4)

        let activity = optIn("Track app & window activity")
        let textContext = optIn("Capture visible text context")
        let visualContext = optIn("Add encrypted visual context")
        for option in [activity, textContext, visualContext] {
            XCTAssertTrue(option.waitForExistence(timeout: 4),
                          "day-memory opt-in missing")
        }
        XCTAssertTrue(text(containing: "app activity, visible text, and encrypted visual context selected")
            .exists, "day-memory page did not explain its enabled defaults")

        // Visual context starts selected, so onboarding exposes its macOS grant.
        app.buttons["Continue to permissions"].click()
        assertPage(title: "Grant LokalBot access", step: 5)
        XCTAssertTrue(text(containing: "Screen Recording").waitForExistence(timeout: 5),
                      "visual-context default did not expose its required permission")

        app.buttons["Back"].click()
        assertPage(title: "Remember your day?", step: 4)
        optIn("Add encrypted visual context").click()
        app.buttons["Continue to permissions"].click()
        assertPage(title: "Grant LokalBot access", step: 5)
        XCTAssertFalse(text(containing: "Screen Recording").exists,
                       "visual-context opt-out kept requesting Screen Recording")
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

    private func optIn(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)["onboarding.optIn.\(title)"].firstMatch
    }
}
