import XCTest

/// End-to-end coverage for Agent Mode's multi-session workspace. The host is
/// explicitly launched in a UI-only ready state, so these tests exercise the
/// real SwiftUI tab manager without warming a model, installing Pi, issuing a
/// filesystem capability, or spawning a subprocess.
final class AgentModeUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        let launch = try UITestHarness.launch(
            storageRoot: fixture.root,
            suitePrefix: "AgentMode",
            environment: ["LOKALBOT_AGENT_UI_TEST_READY": "1"])
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName

        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 10), "main window never rendered its Today landing")
        clickSidebarItem("sidebar.agent")
        XCTAssertTrue(app.descendants(matching: .any)["agent.tabs"]
            .waitForExistence(timeout: 8), "Agent session tabs did not render")
        XCTAssertTrue(app.textFields["agent.composer"].waitForExistence(timeout: 6),
                      "Agent composer did not reach its ready state")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testAddingSessionsStopsAtFourAndKeepsOneWorkspaceVisible() {
        XCTAssertEqual(openTabButtons.count, 1, "Agent Mode should start with one session")
        XCTAssertTrue(openTab(named: "Session 1").exists, "initial session title missing")

        let add = app.buttons["agent.newSession"]
        XCTAssertTrue(add.waitForExistence(timeout: 4), "new-session control missing")

        // Cmd-T is the standard macOS new-tab command and remains reachable on
        // GitHub's 1024-point hosted desktop even when the trailing + button is
        // outside the synthetic window's visible region.
        for expectedCount in 2...4 {
            app.typeKey("t", modifierFlags: .command)
            XCTAssertTrue(UITestHarness.waitUntil {
                self.openTabButtons.count == expectedCount
            }, "Agent Mode did not create session \(expectedCount) via Cmd-T")
        }

        XCTAssertTrue(openTab(named: "Session 4").exists, "fourth session title missing")
        XCTAssertEqual(app.textFields.matching(
            NSPredicate(format: "identifier == 'agent.composer'")).count, 1,
            "only the selected session should be exposed to accessibility")

        app.typeKey("t", modifierFlags: .command)
        XCTAssertFalse(UITestHarness.waitUntil(timeout: 1) { self.openTabButtons.count > 4 },
                       "Agent Mode exceeded its four-session safety limit")
        XCTAssertEqual(openTabButtons.count, 4)
    }

    func testClosingDraftSessionRequiresConfirmationAndFinalCloseReplacesIt() {
        let composer = app.textFields["agent.composer"]
        composer.click()
        composer.typeText("Review the latest meeting notes")

        closeTabButtons.firstMatch.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5),
                      "closing a session with a draft should ask for confirmation")
        XCTAssertTrue(sheet.buttons["Close Session"].exists,
                      "destructive close action missing")
        sheet.buttons["Cancel"].click()

        XCTAssertTrue(openTab(named: "Session 1").waitForExistence(timeout: 3),
                      "cancelled close removed the session")
        XCTAssertEqual(composer.value as? String, "Review the latest meeting notes",
                       "cancelled close discarded the unsent draft")

        closeTabButtons.firstMatch.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5),
                      "close confirmation did not reappear")
        sheet.buttons["Close Session"].click()

        XCTAssertTrue(UITestHarness.waitUntil {
            self.openTabButtons.count == 1 && self.openTab(named: "Session 2").exists
        }, "closing the final tab did not create a fresh replacement session")
        XCTAssertFalse(openTab(named: "Session 1").exists,
                       "closed Agent session remained in the tab strip")
    }

    func testReturningToAgentKeepsDraftWithoutRuntimeLoadingGate() {
        let composer = app.textFields["agent.composer"]
        composer.click()
        composer.typeText("Keep this draft while I check Today")

        clickSidebarItem("sidebar.today")
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 5), "Today did not render after leaving Agent Mode")

        clickSidebarItem("sidebar.agent")
        XCTAssertTrue(app.descendants(matching: .any)["agent.tabs"]
            .waitForExistence(timeout: 2), "Agent tabs did not return immediately")
        XCTAssertFalse(app.staticTexts["Checking Agent runtime…"].exists)
        XCTAssertFalse(app.staticTexts["Verifying Agent runtime…"].exists)
        XCTAssertTrue(composer.waitForExistence(timeout: 2), "Agent composer did not return")
        XCTAssertEqual(composer.value as? String, "Keep this draft while I check Today",
                       "Agent navigation discarded the session draft")
    }

    private var openTabButtons: XCUIElementQuery {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'agent.tab.' AND NOT identifier CONTAINS '.close.'"))
    }

    private var closeTabButtons: XCUIElementQuery {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'agent.tab.close.'"))
    }

    private func openTab(named title: String) -> XCUIElement {
        openTabButtons.matching(NSPredicate(
            format: "label CONTAINS[c] %@", title)).firstMatch
    }

    /// SwiftUI propagates the row identifier to both its icon and label on
    /// current macOS, while the actual List row remains the hit target. Clicking
    /// the unique label coordinate reliably delivers the event to that row.
    private func clickSidebarItem(_ identifier: String) {
        let label = app.staticTexts[identifier]
        XCTAssertTrue(label.waitForExistence(timeout: 4), "Missing sidebar item \(identifier)")
        label.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }
}
