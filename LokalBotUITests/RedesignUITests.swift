import XCTest

/// Hosted-only review of the integrated redesign against synthetic evidence.
/// Screenshots remain in the test result bundle; no private library is used.
final class RedesignUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var suite: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
    }
    override func tearDownWithError() throws {
        app?.terminate()
        UITestHarness.cleanUp(defaultsSuiteName: suite)
        fixture?.cleanUp()
    }

    func testWorkspaceVisualMatrix() throws {
        for size in ["1000x700", "1180x740", "1440x900"] {
            for appearance in ["light", "dark"] {
                try launch(["LOKALBOT_CAPTURE_SIZE": size, "LOKALBOT_CAPTURE_APPEARANCE": appearance,
                            "LOKALBOT_SCREEN_MEMORY_DEMO": "1"])
                XCTAssertTrue(element("today.header").waitForExistence(timeout: 8))
                snapshot("\(size)-\(appearance)-today")
                app.buttons["Review actions"].click()
                XCTAssertTrue(element("actions.list").waitForExistence(timeout: 4))
                snapshot("\(size)-\(appearance)-actions")
                UITestHarness.clickSidebar("sidebar.meetings", in: app)
                let row = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@",
                    fixture.designReview.title, fixture.designReview.title)).firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 5))
                row.click()
                XCTAssertTrue(element("meeting.contentTabs").waitForExistence(timeout: 5))
                snapshot("\(size)-\(appearance)-meeting")
                UITestHarness.selectSegment("Transcript", pickerIdentifier: "meeting.contentTabs", in: app)
                snapshot("\(size)-\(appearance)-transcript")
                UITestHarness.clickSidebar("sidebar.timeline", in: app)
                XCTAssertTrue(element("timeline.workSessions").waitForExistence(timeout: 5))
                snapshot("\(size)-\(appearance)-timeline")
                UITestHarness.clickSidebar("sidebar.ask", in: app)
                UITestHarness.selectSegment("Search", pickerIdentifier: "ask.retrieval", in: app)
                let input = app.textFields["search.field"]
                input.click(); input.typeText("failover")
                XCTAssertTrue(element("search.hit.\(fixture.designReview.id.uuidString).segment").waitForExistence(timeout: 6))
                snapshot("\(size)-\(appearance)-search")
                UITestHarness.clickSidebar("sidebar.settings", in: app)
                UITestHarness.selectSettingsCategory("Privacy & Data", in: app)
                snapshot("\(size)-\(appearance)-settings")
            }
        }
    }

    func testSearchReturnIsSilentAndExplicitAskReviewsScope() throws {
        try launch()
        UITestHarness.clickSidebar("sidebar.ask", in: app)
        UITestHarness.selectSegment("Search", pickerIdentifier: "ask.retrieval", in: app)
        let input = app.textFields["search.field"]
        input.click(); input.typeText("failover")
        XCTAssertTrue(element("search.hit.\(fixture.designReview.id.uuidString).segment").waitForExistence(timeout: 6))
        input.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["transcript.segment.3.text"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["chat.message.user"].exists)
        XCTAssertTrue(app.buttons["Play"].exists, "Evidence should be paused until Play is chosen")
        app.buttons["Back"].click()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "failover")
        app.buttons["ask.escalate"].click()
        XCTAssertTrue(element("ask.selectedEvidence").exists)
        XCTAssertFalse(app.staticTexts["chat.message.user"].exists)
        snapshot("bounded-ask-draft")
    }

    func testAutocompleteAcceptsPhysicalTabAndEscapeDismissesGhost() throws {
        try launch(["LOKALBOT_COTYPING_DEMO": "1"])
        UITestHarness.clickSidebar("sidebar.type", in: app)
        UITestHarness.selectSegment("Autocomplete", pickerIdentifier: "type.tab", in: app)
        let start = app.buttons["Start"]
        UITestHarness.scrollTo(start, in: app)
        start.click()
        XCTAssertTrue(UITestHarness.waitUntil { self.app.buttons["Insert suggestion"].isEnabled })
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(UITestHarness.staticText(containing: "Rehearsal complete", in: app).waitForExistence(timeout: 4))
        app.buttons["Restart"].click()
        XCTAssertTrue(UITestHarness.waitUntil { self.app.buttons["Insert suggestion"].isEnabled })
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.buttons["Insert suggestion"].isEnabled)
        XCTAssertFalse(UITestHarness.staticText(containing: "Rehearsal complete", in: app).exists)
        snapshot("autocomplete-keyboard-rehearsal")
    }

    func testContrastAndReducedMotionKeepActionsAccessible() throws {
        try launch(["LOKALBOT_CAPTURE_APPEARANCE": "contrast-dark"])
        XCTAssertTrue(app.buttons["toolbar.record"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(element("settings.categories").waitForExistence(timeout: 5))
        app.textFields["settings.search"].click()
        app.textFields["settings.search"].typeText("retention")
        XCTAssertTrue(element("settings.searchResults").waitForExistence(timeout: 5))
        snapshot("settings-contrast-reduced-motion")
    }

    private func launch(_ environment: [String: String] = [:]) throws {
        app?.terminate()
        UITestHarness.cleanUp(defaultsSuiteName: suite)
        let run = try UITestHarness.launch(storageRoot: fixture.root, suitePrefix: "Redesign", environment: environment)
        app = run.app; suite = run.defaultsSuiteName
    }
    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
