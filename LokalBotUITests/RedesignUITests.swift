import AppKit
import XCTest

/// Hosted-only review of the integrated redesign against synthetic evidence.
/// Screenshots remain in the test result bundle; no private library is used.
final class RedesignUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var suite: String?
    private var previousVisualFixtures: [SyntheticFixture.Library] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
    }
    override func tearDownWithError() throws {
        app?.terminate()
        UITestHarness.cleanUp(defaultsSuiteName: suite)
        fixture?.cleanUp()
        previousVisualFixtures.forEach { $0.cleanUp() }
    }

    func testWorkspaceVisualMatrix() throws {
        let routes: [(String, [String: String])] = [
            ("today", ["LOKALBOT_INITIAL_SECTION": "today"]),
            ("actions", ["LOKALBOT_INITIAL_ACTIONS": "1"]),
            ("meeting", ["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0"]),
            ("transcript", ["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0", "LOKALBOT_DETAIL_TAB": "transcript"]),
            ("timeline", ["LOKALBOT_INITIAL_SECTION": "timeline"]),
            ("search", ["LOKALBOT_INITIAL_SECTION": "ask", "LOKALBOT_INITIAL_ASK_MODE": "search", "LOKALBOT_INITIAL_SEARCH": "failover"]),
            ("ask", ["LOKALBOT_INITIAL_SECTION": "ask"]),
            ("settings", ["LOKALBOT_INITIAL_SECTION": "settings", "LOKALBOT_INITIAL_SETTINGS_CATEGORY": "privacy"]),
            ("models", ["LOKALBOT_INITIAL_SECTION": "models"]),
            ("dictation", ["LOKALBOT_INITIAL_SECTION": "dictation"]),
            ("autocomplete", ["LOKALBOT_INITIAL_SECTION": "autocomplete", "LOKALBOT_COTYPING_DEMO": "1"]),
            ("agent", ["LOKALBOT_INITIAL_SECTION": "agent", "LOKALBOT_AGENT_DEMO": "1"]),
        ]
        for size in ["1000x700", "1180x740", "1440x900"] {
            for appearance in ["light", "dark"] {
                for (route, state) in routes {
                    // A complete matrix can cross midnight. Keep Today and
                    // Timeline populated on the new civil day, while retaining
                    // earlier attachment files until XCTest serializes them.
                    if !Calendar.current.isDateInToday(fixture.designReview.startedAt) {
                        previousVisualFixtures.append(fixture)
                        fixture = try SyntheticFixture.plant()
                    }
                    let name = "\(size)-\(appearance)-\(route)"
                    let destination = fixture.root.appendingPathComponent(name + ".png")
                    var environment = state
                    environment.merge([
                        "LOKALBOT_CAPTURE_FILE": destination.path,
                        "LOKALBOT_CAPTURE_SIZE": size, "LOKALBOT_CAPTURE_SCALE": "1", "LOKALBOT_CAPTURE_DELAY": "8",
                        "LOKALBOT_CAPTURE_APPEARANCE": appearance, "LOKALBOT_SCREEN_MEMORY_DEMO": "1",
                        "LOKALBOT_AGENT_UI_TEST_READY": "1",
                    ]) { _, value in value }
                    try launch(environment)
                    XCTAssertTrue(UITestHarness.waitUntil(timeout: 20) { FileManager.default.fileExists(atPath: destination.path) },
                                  "Native capture did not finish: \(name)")
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: destination)))
                    XCTAssertEqual(bitmap.pixelsWide, Int(size.split(separator: "x")[0]), "Capture width must match the requested layout")
                    XCTAssertEqual(bitmap.pixelsHigh, Int(size.split(separator: "x")[1]), "Capture height must match the requested layout")
                    let attachment = XCTAttachment(contentsOfFile: destination)
                    attachment.name = name; attachment.lifetime = .keepAlways
                    add(attachment)
                }
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
        app.buttons["Back"].firstMatch.click()
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
        let editor = app.textViews["autocomplete.rehearsal.editor"]
        let textBeforeNavigation = editor.value as? String
        XCTAssertNotNil(textBeforeNavigation)
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(editor.value as? String, textBeforeNavigation, "Tab without a suggestion should navigate, not insert a tab")
        app.typeKey(.tab, modifierFlags: .shift)
        XCTAssertEqual(editor.value as? String, textBeforeNavigation, "Shift-Tab should preserve the rehearsal text")
        snapshot("autocomplete-keyboard-rehearsal")
    }

    func testHighContrastKeepsActionsAccessible() throws {
        try launch(["LOKALBOT_CAPTURE_APPEARANCE": "contrast-dark"])
        XCTAssertTrue(app.buttons["toolbar.record"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(element("settings.categories").waitForExistence(timeout: 5))
        app.textFields["settings.search"].click()
        app.textFields["settings.search"].typeText("retention")
        XCTAssertTrue(element("settings.searchResults").waitForExistence(timeout: 5))
        XCTAssertTrue(UITestHarness.staticText(containing: "Results across all categories", in: app).exists)
        // Report every audit issue in one hosted result, retaining the failing
        // status while avoiding serial runs to discover one missing name at a time.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .action])
        snapshot("settings-high-contrast")
    }

    func testReducedMotionWorkspaceRemainsOperable() throws {
        guard UserDefaults(suiteName: "org.localhost.lokalbot.redesign-ci")?.bool(forKey: "requiresReducedMotion") == true else {
            throw XCTSkip("Runs in the dedicated hosted Reduce Motion step")
        }
        XCTAssertTrue(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "The hosted runner must actually enable Reduce Motion")
        try launch(["LOKALBOT_CAPTURE_APPEARANCE": "contrast-dark", "LOKALBOT_SCREEN_MEMORY_DEMO": "1"])
        UITestHarness.clickSidebar("sidebar.timeline", in: app)
        XCTAssertTrue(element("timeline.workSessions").waitForExistence(timeout: 5))
        UITestHarness.clickSidebar("sidebar.ask", in: app)
        UITestHarness.selectSegment("Search", pickerIdentifier: "ask.retrieval", in: app)
        app.textFields["search.field"].click()
        app.textFields["search.field"].typeText("failover")
        XCTAssertTrue(element("search.hit.\(fixture.designReview.id.uuidString).segment").waitForExistence(timeout: 6))
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .action])
        snapshot("search-reduced-motion")
    }

    func testRetentionReviewCancelPreservesPolicy() throws {
        try launch(["LOKALBOT_SCREEN_MEMORY_DEMO": "1"])
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("Privacy & Data", in: app)
        let before = UserDefaults(suiteName: suite!)?.data(forKey: "lokalbotv3.settings")
        let review = app.buttons["Review expired context…"]
        UITestHarness.scrollTo(review, in: app)
        review.click()
        XCTAssertTrue(app.buttons["retention.confirm"].waitForExistence(timeout: 5))
        snapshot("retention-review-before-cancel")
        app.buttons["Cancel"].click()
        XCTAssertTrue(UITestHarness.waitUntil { !self.app.buttons["retention.confirm"].exists },
                      "Cancel should close retention review without applying its policy")
        XCTAssertEqual(UserDefaults(suiteName: suite!)?.data(forKey: "lokalbotv3.settings"), before)
    }

    func testFourHundredActionsStaySearchableAndCompletionCanBeUndone() throws {
        let folder = fixture.folder(for: fixture.designReview)
        let actions: [[String: Any]] = (0..<400).map { index in
            ["id": "large-action-\(index)", "schemaVersion": 2, "text": "Synthetic commitment \(index)",
             "owner": "Me", "isForUser": true, "due": "Friday", "citations": []]
        }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "actionItems": actions])
        try data.write(to: folder.appendingPathComponent("outcomes.json"))
        try launch()
        app.buttons["Review actions"].click()
        let search = app.textFields["actions.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click(); search.typeText("Synthetic commitment 399")
        let action = UITestHarness.staticText(containing: "Synthetic commitment 399", in: app)
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.click()
        search.click(); search.typeKey("a", modifierFlags: .command)
        search.typeText("Synthetic commitment 398")
        XCTAssertTrue(element("actions.selection.hidden").waitForExistence(timeout: 5),
                      "Filtering should preserve the selected action while excluding it from the batch")
        XCTAssertFalse(element("actions.batch").isEnabled)
        search.click(); search.typeKey("a", modifierFlags: .command)
        search.typeText("Synthetic commitment 399")
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertTrue(element("actions.batch").isEnabled, "Returning to the action should restore its selection")
        XCTAssertFalse(element("actions.selection.hidden").exists)
        let complete = app.buttons["outcome.action.toggle.\(fixture.designReview.id.uuidString):large-action-399"]
        XCTAssertTrue(complete.waitForExistence(timeout: 4))
        complete.click()
        XCTAssertTrue(UITestHarness.waitUntil { !action.exists })
        app.buttons["outcomes.undo"].click()
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        snapshot("four-hundred-actions-search-and-undo")
    }

    func testAgentApprovalDescribesEffectAndDenialAndStopReachTheController() throws {
        try launch(["LOKALBOT_AGENT_UI_TEST_READY": "1", "LOKALBOT_AGENT_UI_TEST_APPROVAL": "1"])
        UITestHarness.clickSidebar("sidebar.agent", in: app)
        let composer = app.textFields["agent.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 6))
        composer.click(); composer.typeText("Draft a meeting follow-up")
        app.buttons["agent.send"].click()
        let deny = app.buttons["agent.approve.deny"]
        XCTAssertTrue(deny.waitForExistence(timeout: 6))
        XCTAssertTrue(UITestHarness.staticText(containing: "Create or replace the file", in: app).exists)
        XCTAssertTrue(UITestHarness.staticText(containing: "reviewed-note.md", in: app).exists)
        snapshot("agent-write-approval")
        deny.click()
        XCTAssertTrue(UITestHarness.staticText(containing: "You denied this write request", in: app)
            .waitForExistence(timeout: 4))
        XCTAssertFalse(deny.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("reviewed-note.md").path))
        app.buttons["agent.stop"].click()
        XCTAssertTrue(UITestHarness.waitUntil { !self.app.buttons["agent.stop"].exists })
        let lines = try String(contentsOf: fixture.root.appendingPathComponent("agent-ui-rpc.jsonl"), encoding: .utf8)
        let commands = try lines.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertTrue(commands.contains { $0["type"] as? String == "extension_ui_response" && $0["confirmed"] as? Bool == false })
        XCTAssertEqual(commands.last?["type"] as? String, "abort")
        snapshot("agent-denied-and-stopped")
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
