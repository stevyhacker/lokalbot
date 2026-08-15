import XCTest

/// End-to-end coverage for the approved Autocomplete-first Type experience.
/// The legacy cotyping keys remain internal; user-facing language and routes
/// are Autocomplete throughout.
final class CotypingSettingsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fixture: SyntheticFixture.Library!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        let launch = try UITestHarness.launch(
            storageRoot: fixture.root,
            suitePrefix: "Autocomplete",
            environment: ["LOKALBOT_COTYPING_DEMO": "1"])
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 10), "main window never rendered")
        UITestHarness.clickSidebar("sidebar.type", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["autocomplete.home"]
            .waitForExistence(timeout: 8), "Autocomplete did not lead Type for a new install")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testAutocompleteExperienceShowsReadinessPreviewAndPrivacy() {
        XCTAssertTrue(staticText("Ready to type").exists)
        XCTAssertTrue(staticText("Try the real autocomplete").exists)
        XCTAssertTrue(staticText("Two-step rehearsal").exists)
        XCTAssertTrue(staticText("Private by design").exists)
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Accept '")).firstMatch.exists)
        XCTAssertFalse(staticText("Cotyping").exists,
                       "legacy internal name leaked into the user-facing Type surface")
    }

    func testAutocompleteSettingsHandoffLandsInGeneral() {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 4), "Settings handoff missing")
        settings.click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.form"]
            .waitForExistence(timeout: 6), "Settings did not open")
        XCTAssertTrue(staticText("Autocomplete").waitForExistence(timeout: 5),
                      "General did not expose Autocomplete settings")
    }

    func testAutocompleteTabPersistsAcrossNavigation() {
        UITestHarness.clickSidebar("sidebar.timeline", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 6), "Timeline did not render")
        UITestHarness.clickSidebar("sidebar.type", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["autocomplete.home"]
            .waitForExistence(timeout: 8), "Autocomplete tab was not restored")
        XCTAssertFalse(app.descendants(matching: .any)["dictation.form"].exists)
    }

    private func staticText(_ fragment: String) -> XCUIElement {
        UITestHarness.staticText(containing: fragment, in: app)
    }
}
