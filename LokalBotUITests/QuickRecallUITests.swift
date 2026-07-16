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
        if name.contains("testSearchShowsLocalMeetingEvidenceAndAskFallback") {
            // Seed the complete query before SwiftUI mounts. The clear test
            // below still drives real typing, while this result test avoids a
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

    func testSearchShowsLocalMeetingEvidenceAndAskFallback() {
        XCTAssertEqual(input.value as? String, "failover",
                       "seeded Quick Recall query did not render")

        let meetingPrefix = "quickRecall.row.meeting.\(fixture.designReview.id.uuidString).segment."
        let meetingTitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            meetingPrefix, fixture.designReview.title, fixture.designReview.title)).firstMatch
        XCTAssertTrue(meetingTitle.waitForExistence(timeout: 8),
            "Quick Recall did not surface the matching meeting")

        let meetingSubtitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == 'Meeting transcript' OR value == 'Meeting transcript')",
            meetingPrefix)).firstMatch
        XCTAssertTrue(meetingSubtitle.waitForExistence(timeout: 3),
                      "Quick Recall did not identify the local evidence type")

        let askSubtitle = app.staticTexts.matching(NSPredicate(
            format: "identifier == 'quickRecall.row.ask.failover' AND (label == 'Open Ask' OR value == 'Open Ask')"))
            .firstMatch
        XCTAssertTrue(askSubtitle.waitForExistence(timeout: 3),
                      "Quick Recall did not include the assistant fallback")
    }

    func testClearReturnsToSavedMomentEmptyState() {
        XCTAssertTrue(text(containing: "No saved moments yet")
            .waitForExistence(timeout: 5), "initial Quick Recall empty state missing")
        input.click()
        input.typeText("nothing-local-matches-this")

        let clear = app.buttons["Clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 4), "Quick Recall clear control missing")
        XCTAssertTrue(text(containing: "Open Ask").waitForExistence(timeout: 4),
                      "assistant fallback missing for an unmatched query")
        clear.click()

        XCTAssertTrue(text(containing: "No saved moments yet")
            .waitForExistence(timeout: 5), "clearing did not restore the empty state")
        XCTAssertFalse(clear.exists, "clear control remained visible for an empty query")
    }

    private var input: XCUIElement {
        app.textFields["quickRecall.input"]
    }

    private func text(containing fragment: String) -> XCUIElement {
        UITestHarness.staticText(containing: fragment, in: app)
    }
}
