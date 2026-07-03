import XCTest

/// End-to-end UI tests that drive the dedicated `LokalBot UI Test Host`
/// against a synthetic meetings library planted on disk before launch.
///
/// The app sees `LOKALBOT_UI_TEST=1` and skips every side-effectful
/// startup path (Core Audio polling, accessibility-trusted detector,
/// Sparkle, screenshots), so the suite needs no TCC permissions and
/// never touches the user's real library.
final class MainWindowUITests: XCTestCase {

    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        let launch = try UITestHarness.launch(storageRoot: fixture.root, suitePrefix: "MainWindow")
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        // Wait until the main window has rendered the Capture scope control —
        // every test starts from a known surface, otherwise XCUITest races
        // the initial `loadMeetings()` + reindex sweep. (With seeded activity
        // the default scope is Day, so the meeting list is NOT on screen yet.)
        XCTAssertTrue(app.descendants(matching: .any)["capture.scope"]
            .waitForExistence(timeout: 10), "capture scope control never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    // MARK: - Library

    /// Every planted fixture surfaces in the sidebar, grouped by day with
    /// the right headers — confirms `StorageManager.loadMeetings()` reads
    /// our on-disk shape, not just a happy-path single meeting.
    func testMeetingListRendersAllSyntheticMeetings() {
        openLibrary()
        let list = app.outlines["meeting.list"]
        XCTAssertTrue(list.staticTexts[fixture.designReview.title].exists,
                      "design review row missing")
        XCTAssertTrue(list.staticTexts[fixture.standup.title].exists,
                      "standup row missing")
        XCTAssertTrue(list.staticTexts[fixture.planning.title].exists,
                      "planning row missing")
        XCTAssertTrue(hasDayHeader(in: list, prefix: "TODAY"),
                      "TODAY day header missing")
        XCTAssertTrue(hasDayHeader(in: list, prefix: "YESTERDAY"),
                      "YESTERDAY day header missing")
        // The Record toolbar button is always present; assert it exists but
        // never click it — recording reaches for real audio devices.
        XCTAssertTrue(app.buttons["toolbar.record"].exists,
                      "record toolbar button missing")
    }

    /// Sidebar selection swaps the content column. Settings is the most
    /// distinctive surface (rich form) — switching to it and back proves
    /// `AppState.navSection` round-trips through the bound selection.
    func testSidebarNavigationSwitchesSections() {
        clickSidebar("sidebar.settings")
        XCTAssertTrue(app.descendants(matching: .any)["settings.form"]
            .waitForExistence(timeout: 6),
                      "settings pane did not render")
        XCTAssertTrue(app.buttons["Relaunch"].waitForExistence(timeout: 4),
                      "permissions section missing from Settings")

        clickSidebar("sidebar.capture")
        XCTAssertTrue(app.descendants(matching: .any)["capture.scope"]
            .waitForExistence(timeout: 4),
                      "capture section did not come back")
    }

    /// The Models tab of Settings (spec §2.5) renders its role cards —
    /// Models is reached via Settings' tab strip, not its own sidebar entry.
    func testModelsSectionRendersRoleCards() {
        clickSidebar("sidebar.settings")
        let tabs = app.descendants(matching: .any)["settings.tab"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 8), "settings tab strip missing")
        let segment = tabs.buttons["Models"].exists
            ? tabs.buttons["Models"] : tabs.radioButtons["Models"]
        XCTAssertTrue(segment.waitForExistence(timeout: 4), "Models segment missing")
        segment.click()
        XCTAssertTrue(textWithContent("Transcription").firstMatch
            .waitForExistence(timeout: 6),
                      "Models pane did not render the Transcription card")
        XCTAssertTrue(textWithContent("Summarization").firstMatch.exists,
                      "Models pane missing the Summarization card")
        XCTAssertTrue(app.descendants(matching: .any)["models.transcription"].exists,
                      "transcription model card identifier missing")
        XCTAssertTrue(app.descendants(matching: .any)["models.summarization"].exists,
                      "summarization model card identifier missing")
        XCTAssertTrue(app.descendants(matching: .any)["models.cotyping"].exists,
                      "cotyping model card identifier missing")
        XCTAssertTrue(app.descendants(matching: .any)["models.embeddings"].exists,
                      "embeddings model card identifier missing")
    }

    // MARK: - Capture (Day scope)

    /// Capture's Day scope renders the merged surface from the seeded
    /// `activity_blocks` + meetings: the hour track (with a seeded block
    /// title and a meeting block in the teal lane) on the left, and the day
    /// overview's per-app totals in the detail pane — the old inspector's
    /// four-tab control is gone (spec §2.2).
    func testCaptureDayRendersTrackAndOverview() {
        clickSidebar("sidebar.capture")
        // Seeded activity → the scope policy defaults to Day.
        XCTAssertTrue(textWithContent("Time by app").firstMatch.waitForExistence(timeout: 6),
                      "day-overview totals headline missing — seeded activity did not load")
        XCTAssertTrue(textWithContent("Xcode").firstMatch.exists,
                      "seeded activity app 'Xcode' missing from Capture")
        XCTAssertFalse(textWithContent("No activity recorded").firstMatch.exists,
                       "empty state shown despite seeded activity blocks")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"].exists,
                      "hour track identifier missing")
        // The block *title* renders only inside the hour track (totals rows
        // show app names, never titles), so this pins down the track itself.
        XCTAssertTrue(textWithContent("TimelineView.swift").firstMatch.exists,
                      "seeded block title missing from the hour track")
        // Meetings are first-class track blocks now (spec §2.2).
        XCTAssertTrue(app.descendants(matching: .any)["capture.meeting.\(fixture.designReview.id.uuidString)"].exists,
                      "seeded meeting block missing from the track's meeting lane")
        // The four-tab inspector is gone.
        XCTAssertFalse(app.descendants(matching: .any)["timeline.inspector"].exists,
                       "legacy inspector segmented control should be removed")
    }

    /// The Day⇄Library scope control swaps the Capture content column both
    /// ways: Day shows the hour track, Library shows the grouped meeting
    /// list (spec §6: "Capture Day⇄Library toggle").
    func testCaptureScopeTogglesBetweenDayAndLibrary() {
        clickSidebar("sidebar.capture")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"]
            .waitForExistence(timeout: 6), "Day scope should be the default with seeded activity")

        openLibrary()
        XCTAssertFalse(app.descendants(matching: .any)["timeline.track"].exists,
                       "hour track should leave the screen in Library scope")

        let picker = app.descendants(matching: .any)["capture.scope"]
        let daySegment = picker.buttons["Day"].exists
            ? picker.buttons["Day"] : picker.radioButtons["Day"]
        daySegment.click()
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"]
            .waitForExistence(timeout: 4), "hour track did not come back in Day scope")
    }

    // MARK: - Detail tabs

    /// Selecting a meeting → detail pane shows title + summary; flipping the
    /// segmented tabs reveals transcript content. Asserts the actual text we
    /// planted, so a regression in `MeetingDetailView.loadFiles` or the
    /// `MarkdownText` renderer would surface as a missing string.
    func testMeetingDetailTabsLoadSummaryAndTranscript() {
        openLibrary()
        selectMeeting(fixture.designReview)

        let title = app.staticTexts["detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        // SwiftUI `Text` puts the rendered string in AXValue, not AXLabel.
        XCTAssertEqual(title.value as? String, fixture.designReview.title)

        // Summary tab is the default — assert one section header + one bullet.
        XCTAssertTrue(textWithContent("TL;DR").firstMatch.waitForExistence(timeout: 4),
                      "summary TL;DR heading missing")
        XCTAssertTrue(textWithContent("Adopt Redis").firstMatch.exists,
                      "summary decision text missing")

        // Flip to transcript and verify a planted segment renders. The
        // SwiftUI segmented Picker renders each tab as a button/radio
        // segment, not a static text — query the identifier without
        // restricting to an element type.
        let transcriptTab = app.descendants(matching: .any)["detail.tab.transcript"]
        XCTAssertTrue(transcriptTab.waitForExistence(timeout: 3),
                      "transcript segmented control tab missing")
        transcriptTab.click()
        XCTAssertTrue(textWithContent("eviction policy").firstMatch
            .waitForExistence(timeout: 3),
                      "transcript segment text missing")
        // The "Me" speaker chip rendered by `segmentRow` is a StaticText —
        // matching the exact `value` avoids unrelated "Me" substrings.
        XCTAssertGreaterThan(
            app.staticTexts.matching(NSPredicate(format: "value == 'Me'")).count, 0,
            "speaker chip 'Me' missing on transcript")
    }

    // MARK: - Ask

    /// FTS5-backed search reindexes on every launch — typing a term that
    /// only appears in the synthetic transcripts surfaces the matching
    /// meeting, and clicking the hit deep-links to that meeting's detail.
    func testSearchFindsTranscriptHitAndDeepLinks() {
        clickSidebar("sidebar.ask")

        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "search field missing")
        let layoutDeadline = Date().addingTimeInterval(4)
        while field.frame.width < 40, Date() < layoutDeadline { usleep(150_000) }
        field.click()
        field.typeText("failover")

        // The row's accessibility identifier propagates to every StaticText
        // child; take the first match so the click is unambiguous.
        let segmentHit = app.staticTexts.matching(
            NSPredicate(format: "identifier == %@",
                        "search.hit.\(fixture.designReview.id.uuidString).segment"))
            .firstMatch
        XCTAssertTrue(segmentHit.waitForExistence(timeout: 4),
                      "expected design review segment hit for 'failover'")
        segmentHit.click()

        let title = app.staticTexts["detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        XCTAssertEqual(title.value as? String, fixture.designReview.title)
    }

    /// The Ask section is reachable from the sidebar and renders its merged
    /// surface: the empty state, the single input, and — once a query is
    /// typed — the pinned assistant-escalation row above live results.
    /// Stops short of sending (that would spin up the real local LLM).
    func testAskSectionRendersAndAcceptsInput() {
        clickSidebar("sidebar.ask")

        XCTAssertTrue(textWithContent("Ask your meetings").firstMatch
            .waitForExistence(timeout: 6),
                      "ask empty-state did not render")

        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 4), "ask input field missing")
        let layoutDeadline = Date().addingTimeInterval(4)
        while field.frame.width < 40, Date() < layoutDeadline { usleep(150_000) }
        field.click()
        field.typeText("what did we decide")
        XCTAssertEqual(field.value as? String, "what did we decide",
                       "ask input did not accept typed text")

        // Typing switches the pane to results with the pinned escalation row.
        XCTAssertTrue(app.descendants(matching: .any)["ask.escalate"]
            .waitForExistence(timeout: 4),
                      "pinned escalation row missing while searching")
    }

    /// ↵ escalates the query to the assistant: the pane switches from
    /// results to the conversation transcript with the query as the user
    /// turn. The model reply itself is not awaited (no local LLM in the
    /// test host) — the transition and the persisted user turn are the
    /// contract under test.
    func testAskEscalationShowsConversationWithUserTurn() {
        clickSidebar("sidebar.ask")

        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "ask input field missing")
        let layoutDeadline = Date().addingTimeInterval(4)
        while field.frame.width < 40, Date() < layoutDeadline { usleep(150_000) }
        field.click()
        field.typeText("failover")
        XCTAssertTrue(app.descendants(matching: .any)["ask.escalate"]
            .waitForExistence(timeout: 4), "escalation row missing")

        field.typeText("\r")

        let userTurn = app.staticTexts.matching(
            NSPredicate(format: "identifier == %@ AND value CONTAINS[c] %@",
                        "chat.message.user", "failover")).firstMatch
        XCTAssertTrue(userTurn.waitForExistence(timeout: 6),
                      "user turn did not appear in the conversation after ↵")
    }

    // MARK: - Selection

    /// Cmd-clicking a second row enters the multi-select state — the detail
    /// pane swaps to the "N meetings selected" affordance with the deletion
    /// button and the hint copy. Guards against `selectedMeeting` accidentally
    /// returning non-nil for sets larger than one.
    func testMultiSelectShowsAggregateState() {
        openLibrary()
        selectTwo(fixture.designReview, fixture.standup)
        XCTAssertTrue(textWithContent("2 meetings selected").firstMatch.exists,
                      "multi-select headline missing")
        XCTAssertTrue(textWithContent("right-click to delete").firstMatch.exists,
                      "multi-select description missing")
    }

    // MARK: - Delete confirmation

    /// Cancelling the confirmation dialog leaves both the list rows and the
    /// on-disk folders untouched — the dialog is the only friction protecting
    /// recordings from a stray click, so this regression test is load-bearing.
    func testDeleteConfirmationCancelsCleanly() {
        openLibrary()
        let deleteButton = selectTwo(fixture.standup, fixture.planning)
        deleteButton.click()

        // `.confirmationDialog` renders as a Sheet labelled "alert"; scope
        // the Cancel query to that sheet so we don't ambiguously match the
        // TouchBar's own Cancel button when one is present.
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5),
                      "confirmation sheet never appeared")
        sheet.buttons["Cancel"].click()

        XCTAssertTrue(meetingRow(for: fixture.standup).waitForExistence(timeout: 3),
                      "standup meeting must remain after a cancelled delete")
        XCTAssertTrue(meetingRow(for: fixture.planning).exists,
                      "planning meeting must remain after a cancelled delete")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.folder(for: fixture.standup).path),
            "standup folder must survive a cancelled delete")
    }

    /// Confirming runs the full destructive path — MainWindowView →
    /// `AppState.deleteMeetings` → `StorageManager.deleteMeeting` — removing
    /// both the list rows and the on-disk folders. Safe to actually delete:
    /// the fixture lives in a throwaway tmp root.
    func testDeleteConfirmedRemovesMeetingsFromListAndDisk() {
        openLibrary()
        let deleteButton = selectTwo(fixture.standup, fixture.planning)
        let standupFolder = fixture.folder(for: fixture.standup)
        let planningFolder = fixture.folder(for: fixture.planning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: standupFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: planningFolder.path))

        deleteButton.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5),
                      "confirmation sheet never appeared")
        sheet.buttons["Delete (removes recordings & transcripts)"].click()

        // Rows vanish from the list…
        expectation(for: NSPredicate(format: "exists == false"),
                    evaluatedWith: meetingRow(for: fixture.standup))
        expectation(for: NSPredicate(format: "exists == false"),
                    evaluatedWith: meetingRow(for: fixture.planning))
        waitForExpectations(timeout: 5)

        // …and so do their folders on disk.
        XCTAssertFalse(FileManager.default.fileExists(atPath: standupFolder.path),
                       "standup folder must be removed from disk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: planningFolder.path),
                       "planning folder must be removed from disk")
        XCTAssertTrue(meetingRow(for: fixture.designReview).exists,
                      "untouched meeting must remain in the list")
    }

    // MARK: - Helpers

    /// Click a sidebar entry by accessibility identifier. The identifier
    /// lives on the inner `Label`; descend-by-id is unambiguous because
    /// each sidebar item carries a unique identifier (`sidebar.<section>`).
    private func clickSidebar(_ identifier: String) {
        UITestHarness.clickSidebar(identifier, in: app)
    }

    /// Switch Capture to Library scope and wait for the meeting list —
    /// the precondition for every list/detail/delete test.
    private func openLibrary() {
        clickSidebar("sidebar.capture")
        let picker = app.descendants(matching: .any)["capture.scope"]
        XCTAssertTrue(picker.waitForExistence(timeout: 6), "capture scope control missing")
        let segment = picker.buttons["Library"].exists
            ? picker.buttons["Library"] : picker.radioButtons["Library"]
        segment.click()
        XCTAssertTrue(app.outlines["meeting.list"].waitForExistence(timeout: 4),
                      "meeting list did not render in Library scope")
    }

    private func selectMeeting(_ meeting: SyntheticFixture.Meeting) {
        let row = meetingRow(for: meeting)
        XCTAssertTrue(row.waitForExistence(timeout: 4),
                      "meeting row for \(meeting.title) not found")
        row.click()
    }

    /// Select two rows (click + ⌘-click) and wait until the multi-select
    /// detail pane's destructive button appears, so callers begin from a
    /// known multi-select state. Returns that button for the delete flows.
    @discardableResult
    private func selectTwo(_ a: SyntheticFixture.Meeting,
                           _ b: SyntheticFixture.Meeting) -> XCUIElement {
        let first = meetingRow(for: a)
        XCTAssertTrue(first.waitForExistence(timeout: 4),
                      "row for \(a.title) not found")
        first.click()
        // Confirm the first selection committed before extending it: the
        // modifier-held ⌘-click can otherwise race an unsettled selection and
        // land as a plain click (leaving a single selection, so the aggregate
        // "Delete 2 meetings" button never appears).
        _ = app.staticTexts["detail.title"].waitForExistence(timeout: 4)
        XCUIElement.perform(withKeyModifiers: .command) { meetingRow(for: b).click() }
        let deleteButton = app.buttons["Delete 2 meetings"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 4),
                      "multi-select Delete button never appeared")
        return deleteButton
    }

    private func meetingRow(for meeting: SyntheticFixture.Meeting) -> XCUIElement {
        // SwiftUI surfaces the row's accessibility identifier on the merged
        // StaticText element after `.accessibilityElement(children: .combine)`.
        // Multiple children may carry the same identifier; take the first.
        app.staticTexts.matching(
            NSPredicate(format: "identifier == %@",
                        "meeting.row.\(meeting.id.uuidString)"))
            .firstMatch
    }

    /// True when the meeting list shows a day-group header beginning with
    /// `prefix` (e.g. "TODAY", "YESTERDAY"). Checks both `label` and `value`
    /// since SwiftUI may route the header text through either axis.
    private func hasDayHeader(in list: XCUIElement, prefix: String) -> Bool {
        list.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                        prefix, prefix)).count > 0
    }

    /// Match a StaticText whose visible text (`label` or `value`) contains
    /// the fragment, case-insensitively. Scoped to `staticTexts` because
    /// `descendants(matching: .any)` evaluates predicates against every
    /// element type — too slow to use as a routine query.
    private func textWithContent(_ fragment: String) -> XCUIElementQuery {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                        fragment, fragment))
    }
}
