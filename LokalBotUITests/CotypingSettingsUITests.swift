import XCTest

/// End-to-end UI coverage for the Cotyping configuration surface, which lives
/// in the sidebar Cotyping section (its single home — app Settings no longer
/// duplicates it). Everyday controls (extras, privacy exclusions) render as
/// soon as cotyping is enabled; the long tail sits behind a
/// "Show advanced options…" button.
///
/// Like `MainWindowUITests`, this drives the dedicated UI-test host
/// out-of-process against a synthetic library with `LOKALBOT_UI_TEST=1`, so
/// it needs no app TCC permissions and never touches the real library.
///
/// macOS SwiftUI Form `Toggle`/`TextField` elements expose EMPTY accessibility
/// labels — the visible text is a sibling `staticText`. So controls are matched
/// by their label `staticText` (value/label CONTAINS), and the master toggle is
/// driven as the first `switch` INSIDE `cotyping.form` (the header's "Enable
/// cotyping"). Scoping to the form matters: the Type status header above it
/// contributes two switches of its own.
final class CotypingSettingsUITests: XCTestCase {

    private var app: XCUIApplication!
    private var fixture: SyntheticFixture.Library!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        let launch = try UITestHarness.launch(storageRoot: fixture.root, suitePrefix: "CotypingSettings")
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        // Timeline is the default section; with seeded activity the hour
        // track renders, so wait on it rather than the meeting list.
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"]
            .waitForExistence(timeout: 10), "main window never rendered")
        UITestHarness.clickSidebar("sidebar.type", in: app)
        openCotypingTab()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    // MARK: - Helpers

    /// The master toggle — the form's "Enable cotyping" switch, the first
    /// switch inside `cotyping.form`. (The Type status header's switches sit
    /// outside the form, so the form scope skips them.)
    private var masterToggle: XCUIElement {
        app.descendants(matching: .any)["cotyping.form"].switches.firstMatch
    }

    private func setMaster(on desired: Bool) {
        XCTAssertTrue(masterToggle.waitForExistence(timeout: 4), "cotyping master toggle missing")
        scrollToTop()
        let isOn = "\(masterToggle.value ?? "0")" == "1"
        if isOn != desired { masterToggle.click() }
    }

    /// Scrolls the form so `element` becomes hittable (grouped Forms are lazy
    /// lists — off-screen rows may be unhittable even when they exist).
    private func scrollTo(_ element: XCUIElement, upward: Bool = false) {
        let scrollArea = app.scrollViews.firstMatch.exists
            ? app.scrollViews.firstMatch : app.groups.firstMatch
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            scrollArea.scroll(byDeltaX: 0, deltaY: upward ? 300 : -300)
            usleep(120_000)
        }
    }

    private func scrollToTop() {
        let scrollArea = app.scrollViews.firstMatch
        for _ in 0..<12 {
            if masterToggle.exists && masterToggle.isHittable { return }
            scrollArea.scroll(byDeltaX: 0, deltaY: 600)
            usleep(120_000)
        }
    }

    private func staticText(containing fragment: String) -> XCUIElement {
        UITestHarness.staticText(containing: fragment, in: app)
    }

    /// Selects the Cotyping tab in the Type section's segmented control and
    /// waits for the form. Segmented pickers expose their options as buttons
    /// (radio-button fallback covers older accessibility mappings).
    private func openCotypingTab() {
        let picker = app.descendants(matching: .any)["type.tab"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8), "type tab picker missing")
        let segment = picker.buttons["Cotyping"].exists
            ? picker.buttons["Cotyping"] : picker.radioButtons["Cotyping"]
        XCTAssertTrue(segment.waitForExistence(timeout: 4), "Cotyping segment missing")
        segment.click()
        XCTAssertTrue(app.descendants(matching: .any)["cotyping.form"].waitForExistence(timeout: 8),
                      "cotyping pane did not render")
    }

    // MARK: - Tests

    /// The Cotyping section and its master toggle render (the toggle shows even
    /// while cotyping is off — it is what gates the sub-controls).
    func testCotypingSectionAndMasterToggleRender() {
        XCTAssertTrue(masterToggle.exists, "cotyping master toggle missing")
    }

    /// Flipping the master toggle on reveals the everyday controls; the
    /// "Show advanced options…" button then reveals the long tail.
    func testEnablingCotypingRevealsFeatureControls() {
        setMaster(on: true)

        let everydayLabels = [
            "Pause before suggesting",           // suggestions tuning
            "Emoji autocomplete",                // extras
            "Macros (",                          // inline macros
            "Never suggest in",                  // privacy exclusions
            "Use the clipboard as context",      // clipboard context (privacy)
        ]
        for fragment in everydayLabels {
            XCTAssertTrue(staticText(containing: fragment).waitForExistence(timeout: 5),
                          "cotyping control missing after enabling: \(fragment)")
        }

        let advancedButton = app.buttons["Show advanced options…"]
        XCTAssertTrue(advancedButton.waitForExistence(timeout: 5),
                      "advanced options gate missing")
        scrollTo(advancedButton)
        advancedButton.click()

        let advancedLabels = [
            "Match the app",                     // host font/color match
            "Show suggestions",                  // mirror render-mode picker
            "Paste large / multi-line accepts",  // insertion strategy (paste)
            "Suggestions generated",             // quality metrics
        ]
        for fragment in advancedLabels {
            XCTAssertTrue(staticText(containing: fragment).waitForExistence(timeout: 5),
                          "advanced cotyping control missing: \(fragment)")
        }
    }

    /// Toggling cotyping back off hides the gated sub-controls — confirms the
    /// `if cotypingEnabled` gating round-trips through the bound setting.
    func testDisablingCotypingHidesSubControls() {
        setMaster(on: true)
        XCTAssertTrue(staticText(containing: "Use the clipboard as context").waitForExistence(timeout: 5),
                      "clipboard toggle should be visible while enabled")
        setMaster(on: false)
        XCTAssertFalse(staticText(containing: "Use the clipboard as context").exists,
                       "sub-controls should be hidden once cotyping is disabled")
    }

    /// The selected Type tab is session-sticky (spec §6 "Type tab persistence"):
    /// leave for Timeline, come back, and Cotyping is still the visible form.
    func testTypeTabPersistsAcrossNavigation() {
        UITestHarness.clickSidebar("sidebar.timeline", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"].waitForExistence(timeout: 6),
                      "timeline section did not render")
        UITestHarness.clickSidebar("sidebar.type", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["cotyping.form"].waitForExistence(timeout: 8),
                      "cotyping tab was not restored on return to Type")
        XCTAssertFalse(app.descendants(matching: .any)["dictation.form"].exists,
                       "dictation form should not be visible when the cotyping tab is restored")
    }
}
