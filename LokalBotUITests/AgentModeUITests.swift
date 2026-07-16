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

        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"]
            .waitForExistence(timeout: 10), "main window never rendered")
        UITestHarness.clickSidebar("sidebar.agent", in: app)
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

        // The hosted macOS desktop is only 1024 points wide. Collapse the
        // sidebar before driving the trailing tab-bar control so the test
        // exercises the real button without relying on an offscreen click.
        let sidebarToggle = app.toolbars.firstMatch.children(matching: .button).matching(
            NSPredicate(format: "label == 'Hide Sidebar' OR label == 'Show Sidebar'"))
            .firstMatch
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 4),
                      "native sidebar toggle missing")
        sidebarToggle.click()
        XCTAssertTrue(UITestHarness.waitUntil {
            !self.app.descendants(matching: .any)["sidebar.agent"].exists
        }, "sidebar did not collapse before using the Agent tab bar")

        let add = app.buttons["agent.newSession"]
        XCTAssertTrue(add.waitForExistence(timeout: 4), "new-session control missing")
        XCTAssertTrue(UITestHarness.waitUntil { add.isHittable },
                      "new-session control remained outside the visible workspace")
        for _ in 0..<3 { add.click() }

        XCTAssertTrue(UITestHarness.waitUntil { self.openTabButtons.count == 4 },
                      "Agent Mode did not create four independent sessions")
        XCTAssertTrue(openTab(named: "Session 4").exists, "fourth session title missing")
        XCTAssertEqual(app.textFields.matching(
            NSPredicate(format: "identifier == 'agent.composer'")).count, 1,
            "only the selected session should be exposed to accessibility")

        add.click()
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
}
