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

        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"]
            .waitForExistence(timeout: 10), "main window never rendered")
        UITestHarness.clickSidebar("sidebar.type", in: app)
        XCTAssertTrue(dictationForm.waitForExistence(timeout: 8),
                      "Dictation should be the default Type tab")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testComposeByDefaultControlsRenderWithoutStartingRecording() {
        XCTAssertTrue(app.buttons["Start"].exists, "manual Dictation start control missing")
        XCTAssertTrue(masterToggle.waitForExistence(timeout: 4),
                      "global Dictation shortcut control missing")
        XCTAssertFalse(formText(containing: "Records your voice for the current dictation").exists,
                       "permission rows should be hidden while Dictation is disabled")

        let expectedCopy = [
            "always composes the final wording",
            "Show floating pill",
            "Show live transcript while dictating",
            "After composing",
            "Keep dictation audio files",
            "Speech uses the meeting ASR model",
        ]
        for fragment in expectedCopy {
            let label = formText(containing: fragment)
            XCTAssertTrue(label.waitForExistence(timeout: 4),
                          "Dictation compose control missing: \(fragment)")
        }
    }

    func testEnablingGlobalShortcutRevealsPermissionRepairRows() {
        let toggle = masterToggle
        XCTAssertTrue(toggle.waitForExistence(timeout: 4),
                      "Dictation global-shortcut toggle missing")
        toggle.click()

        let permissionDetails = [
            "Records your voice for the current dictation",
            "Detects the global dictation shortcut",
            "Validates the focused field",
            "Optionally reads only the focused window",
        ]
        for fragment in permissionDetails {
            let label = formText(containing: fragment)
            XCTAssertTrue(label.waitForExistence(timeout: 5),
                          "Dictation permission guidance missing: \(fragment)")
        }

        UITestHarness.scrollTo(toggle, in: app, upward: true)
        toggle.click()
        XCTAssertTrue(UITestHarness.waitUntil {
            !self.formText(containing: permissionDetails[0]).exists
        }, "Dictation permission rows remained visible after disabling the shortcut")
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
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"]
            .waitForExistence(timeout: 10), "main window did not return after relaunch")
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
        XCTAssertTrue(app.descendants(matching: .any)["models.dictationComposition"]
            .waitForExistence(timeout: 8), "Models pane did not render Dictation composition")
    }
}
