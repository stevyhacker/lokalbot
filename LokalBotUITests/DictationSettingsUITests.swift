import XCTest

/// Covers the newer compose-by-default Dictation surface and its independent
/// composition-model selector. Tests stop before recording, so no microphone,
/// model download, focused-app insertion, or other real side effect occurs.
final class DictationSettingsUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        let launch = try UITestHarness.launch(
            storageRoot: fixture.root,
            suitePrefix: "DictationSettings")
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName

        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 10), "main window never rendered its Today landing")
        UITestHarness.clickSidebar("sidebar.type", in: app)
        UITestHarness.selectSegment(
            "Dictation", pickerIdentifier: "type.tab", in: app)
        XCTAssertTrue(dictationForm.waitForExistence(timeout: 8),
                      "Dictation tab did not render")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testComposeByDefaultControlsRenderWithoutStartingRecording() {
        XCTAssertTrue(app.buttons["Try here"].exists)
        XCTAssertTrue(formText(containing: "never inserts into another app").exists)
        XCTAssertTrue(app.buttons["Writing settings…"].exists)
        XCTAssertTrue(formText(containing: "Speech uses the meeting ASR model").exists)
        XCTAssertTrue(formText(containing: "Compose").exists)
        XCTAssertFalse(formText(containing: "Listening").exists)
    }

    func testEnablingGlobalShortcutRevealsPermissionRepairRows() {
        app.buttons["Writing settings…"].click()
        let toggle = UITestHarness.toggle("Enable dictation shortcut", in: app)
        UITestHarness.scrollTo(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 4))
        toggle.click()
        UITestHarness.clickSidebar("sidebar.type", in: app)
        XCTAssertTrue(formText(containing: "Records your voice for the current dictation").waitForExistence(timeout: 5))
        XCTAssertTrue(formText(containing: "Detects the global dictation shortcut").exists)
        app.buttons["Writing settings…"].click()
        UITestHarness.scrollTo(toggle, in: app)
        toggle.click()
    }

    func testDedicatedCompositionModelSelectionPersistsAcrossRelaunch() throws {
        openModels()
        var picker = compositionModelPicker
        XCTAssertTrue(picker.waitForExistence(timeout: 6),
                      "Dictation composition model picker missing")
        UITestHarness.scrollTo(picker, in: app)
        picker.click()

        let qwen = app.menuItems["Qwen3.5 2B"]
        XCTAssertTrue(qwen.waitForExistence(timeout: 4),
                      "recommended low-latency Dictation model missing")
        qwen.click()
        XCTAssertTrue(UITestHarness.staticText(containing: "Qwen3.5 2B", in: app)
            .waitForExistence(timeout: 5),
            "Dictation composition card did not render the selected model")

        app = try UITestHarness.relaunch(
            storageRoot: fixture.root,
            defaultsSuiteName: try XCTUnwrap(defaultsSuiteName))
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 10), "main window did not return to Today after relaunch")
        openModels()

        picker = compositionModelPicker
        XCTAssertTrue(picker.waitForExistence(timeout: 6),
                      "composition picker missing after relaunch")
        UITestHarness.scrollTo(picker, in: app)
        XCTAssertTrue(UITestHarness.staticText(containing: "Qwen3.5 2B", in: app)
            .waitForExistence(timeout: 5),
            "dedicated Dictation composition model did not render after relaunch")
    }

    private var dictationForm: XCUIElement {
        app.descendants(matching: .any)["dictation.form"]
    }

    private var masterToggle: XCUIElement {
        app.descendants(matching: .any)["dictation.enabled"]
    }

    private var compositionModelPicker: XCUIElement {
        app.popUpButtons["models.dictationComposition"]
    }

    private func formText(containing fragment: String) -> XCUIElement {
        UITestHarness.staticText(containing: fragment, in: app)
    }

    private func openModels() {
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSegment(
            "Models", pickerIdentifier: "settings.tab", in: app)
        let composition = app.descendants(matching: .any)["models.dictationComposition"]
        UITestHarness.scrollTo(composition, in: app)
        XCTAssertTrue(composition.waitForExistence(timeout: 8),
                      "Models pane did not render Dictation composition")
    }
}
