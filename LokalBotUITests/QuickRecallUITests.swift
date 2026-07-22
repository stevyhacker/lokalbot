import XCTest

/// Covers the compact system-wide Ask window against the same synthetic local
/// library as the main-window search tests.
final class QuickRecallUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        var environment = ["LOKALBOT_UI_TEST_WINDOW": "quick-recall"]
        if name.contains("testSearchShowsLocalMeetingEvidenceAndInlineAsk")
            || name.contains("testBackFromInlineAnswerRestoresRecallQuery") {
            // Seed the complete query before SwiftUI mounts. The clear test
            // below still drives real typing; the result/restore tests avoid a
            // race among eight per-character debounce tasks on hosted Macs.
            environment["LOKALBOT_QUICK_RECALL_QUERY"] = "failover"
        }
        let launch = try UITestHarness.launch(
            storageRoot: fixture.root,
            suitePrefix: "QuickRecall",
            environment: environment)
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        XCTAssertTrue(input.waitForExistence(timeout: 8),
                      "Quick Recall search input did not render")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testSearchShowsLocalMeetingEvidenceAndInlineAsk() {
        XCTAssertEqual(input.value as? String, "failover",
                       "seeded Quick Recall query did not render")

        let meetingPrefix = "quickRecall.row.meeting.\(fixture.designReview.id.uuidString).segment."
        let meetingTitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            meetingPrefix, fixture.designReview.title, fixture.designReview.title)).firstMatch
        XCTAssertTrue(meetingTitle.waitForExistence(timeout: 8),
            "Quick Recall did not surface the matching meeting")

        let meetingSubtitleText = "\(fixture.designReview.appName) · Transcript"
        let meetingSubtitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            meetingPrefix, meetingSubtitleText, meetingSubtitleText)).firstMatch
        XCTAssertTrue(meetingSubtitle.waitForExistence(timeout: 3),
                      "Quick Recall did not identify the local evidence type")

        let askSubtitle = app.staticTexts.matching(NSPredicate(
            format: "identifier == 'quickRecall.row.ask.failover' AND (label == 'Answer from your meetings and screen' OR value == 'Answer from your meetings and screen')"))
            .firstMatch
        XCTAssertTrue(askSubtitle.waitForExistence(timeout: 3),
                      "Quick Recall did not include the inline assistant action")
    }

    func testClearReturnsToAskEmptyState() {
        XCTAssertTrue(text(containing: "Ask anything")
            .waitForExistence(timeout: 5), "initial Quick Recall Ask state missing")
        XCTAssertTrue(app.buttons["quickRecall.suggestion.0"].exists,
                      "Quick Recall did not offer an inline question suggestion")
        input.click()
        input.typeText("nothing-local-matches-this")

        let clear = app.buttons["Clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 4), "Quick Recall clear control missing")
        XCTAssertTrue(text(containing: "Answer from your meetings and screen")
            .waitForExistence(timeout: 4),
                      "inline assistant action missing for an unmatched query")
        XCTAssertTrue(text(containing: "No local matches").waitForExistence(timeout: 4),
                      "Quick Recall did not distinguish a completed empty search")
        // SwiftUI propagates the enclosing no-match state's accessibility ID
        // to descendants on macOS, so select this button by visible content.
        let askInstead = app.buttons.matching(NSPredicate(
            format: "label == 'Ask instead' OR value == 'Ask instead'")).firstMatch
        XCTAssertTrue(askInstead.waitForExistence(timeout: 3),
                      "Quick Recall did not offer an explicit Ask fallback")
        clear.click()

        XCTAssertTrue(text(containing: "Ask anything")
            .waitForExistence(timeout: 5), "clearing did not restore the Ask state")
        XCTAssertFalse(clear.exists, "clear control remained visible for an empty query")
    }

    func testBackFromInlineAnswerRestoresRecallQuery() {
        XCTAssertEqual(input.value as? String, "failover",
                       "seeded Quick Recall query did not render")

        input.typeText("\r")

        let back = app.buttons["Back to recall"]
        XCTAssertTrue(back.waitForExistence(timeout: 6),
                      "inline answer did not expose the recall back control")
        back.click()

        XCTAssertTrue(UITestHarness.waitUntil(timeout: 5) {
            self.input.value as? String == "failover"
        }, "returning from an inline answer discarded the recall query")
    }

    private var input: XCUIElement {
        app.textFields["quickRecall.input"]
    }

    private func text(containing fragment: String) -> XCUIElement {
        UITestHarness.staticText(containing: fragment, in: app)
    }
}
