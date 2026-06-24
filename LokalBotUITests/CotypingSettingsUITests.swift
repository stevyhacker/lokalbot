import XCTest

/// End-to-end UI coverage for the Cotyping settings surface added across the
/// feature batches (emoji, macros, per-domain disable, host font/color match,
/// mirror render mode, clipboard context, paste insertion, quality metrics).
///
/// Like `MainWindowUITests`, this drives `LokalBotV3.app` out-of-process against
/// a synthetic library with `LOKALBOTV3_UI_TEST=1`, so it needs no TCC
/// permissions and never touches the real library.
///
/// macOS SwiftUI Form `Toggle`/`TextField` elements expose EMPTY accessibility
/// labels — the visible text is a sibling `staticText`. So controls are matched
/// by their label `staticText` (value/label CONTAINS), and the master toggle is
/// driven as the lone `switch` left after the settings search isolates the
/// Cotyping section. `cotypingEnabled` defaults off, so the sub-controls only
/// render once that toggle is flipped on.
final class CotypingSettingsUITests: XCTestCase {

    private var app: XCUIApplication!
    private var fixture: SyntheticFixture.Library!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        app = XCUIApplication()
        app.launchEnvironment["LOKALBOTV3_UI_TEST"] = "1"
        app.launchEnvironment["LOKALBOTV3_STORAGE_ROOT"] = fixture.root.path
        app.launch()
        XCTAssertTrue(app.outlines["meeting.list"].waitForExistence(timeout: 10),
                      "main window never rendered")
        clickSidebar("sidebar.settings")
        XCTAssertTrue(staticText(containing: "transcription").waitForExistence(timeout: 8),
                      "settings pane did not render")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
    }

    // MARK: - Helpers

    /// Clicks a sidebar row by identifier using a typed, hittable matcher —
    /// `descendants(.any)[id]` can resolve to a container (e.g. a ScrollView) the
    /// identifier propagated to, which is not clickable.
    private func clickSidebar(_ id: String) {
        for query in [app.buttons, app.cells, app.staticTexts] where query[id].waitForExistence(timeout: 3) {
            let el = query[id]
            if el.isHittable { el.click(); return }
        }
        let any = app.descendants(matching: .any)[id]
        XCTAssertTrue(any.waitForExistence(timeout: 4), "sidebar item \(id) not found")
        any.click()
    }

    /// First `staticText` whose visible text contains `fragment`. SwiftUI routes
    /// `Text` content through AXValue (not AXLabel), so match both, case-insensitively.
    private func staticText(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", fragment, fragment))
            .firstMatch
    }

    /// Types `query` into the settings search (the first text field in the form),
    /// filtering the form down to the Cotyping section so its controls land
    /// on-screen and the master toggle is the only `switch` left.
    private func isolateCotyping() {
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 6), "settings search field missing")
        search.click()
        search.typeText("cotyping")
        XCTAssertTrue(app.staticTexts["Cotyping"].waitForExistence(timeout: 4),
                      "Cotyping section did not isolate")
    }

    /// The master toggle — the sole `switch` once the section is isolated.
    private var masterToggle: XCUIElement { app.switches.firstMatch }

    private func setMaster(on desired: Bool) {
        XCTAssertTrue(masterToggle.waitForExistence(timeout: 4), "cotyping master toggle missing")
        let isOn = "\(masterToggle.value ?? "0")" == "1"
        if isOn != desired { masterToggle.click() }
    }

    // MARK: - Tests

    /// The Cotyping section and its master toggle render (the toggle shows even
    /// while cotyping is off — it is what gates the sub-controls).
    func testCotypingSectionAndMasterToggleRender() {
        isolateCotyping()
        XCTAssertTrue(masterToggle.exists, "cotyping master toggle missing")
    }

    /// Flipping the master toggle on reveals the controls added across the
    /// feature batches.
    func testEnablingCotypingRevealsFeatureControls() {
        isolateCotyping()
        setMaster(on: true)

        let labels = [
            "Emoji autocomplete",                // emoji batch
            "Macros (",                          // inline macros
            "Match the app",                     // host font/color match
            "Show suggestions",                  // mirror render-mode picker
            "Use the clipboard as context",      // clipboard context
            "Paste large / multi-line accepts",  // insertion strategy (paste)
            "Suggestions generated",             // quality metrics
        ]
        for fragment in labels {
            XCTAssertTrue(staticText(containing: fragment).waitForExistence(timeout: 5),
                          "cotyping control missing after enabling: \(fragment)")
        }
    }

    /// Toggling cotyping back off hides the gated sub-controls — confirms the
    /// `if cotypingEnabled` gating round-trips through the bound setting.
    func testDisablingCotypingHidesSubControls() {
        isolateCotyping()
        setMaster(on: true)
        XCTAssertTrue(staticText(containing: "Use the clipboard as context").waitForExistence(timeout: 5),
                      "clipboard toggle should be visible while enabled")
        setMaster(on: false)
        XCTAssertFalse(staticText(containing: "Use the clipboard as context").exists,
                       "sub-controls should be hidden once cotyping is disabled")
    }
}
