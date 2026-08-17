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
        // Wait until the main window has rendered Today's header —
        // every test starts from a known surface, otherwise XCUITest races
        // the initial `loadMeetings()` + reindex sweep. (Today is the
        // default section, so the meeting list is NOT on screen yet.)
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 10), "today header never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    // MARK: - Today

    /// Today keeps the task-first digest hierarchy without repeating the host
    /// page's time chart or exposing capture/evidence bookkeeping.
    func testTodayUsesCompactDigestHierarchy() {
        XCTAssertTrue(textWithContent(SyntheticFixture.todayDigestMarker).firstMatch
            .waitForExistence(timeout: 6), "today's persisted digest did not render")
        XCTAssertTrue(identified("today.dayDigest.generate").waitForExistence(timeout: 5),
                      "Today should expose digest maintenance without another disclosure")
        XCTAssertFalse(identified("today.moreLocalContext").exists,
                       "Today should not hide its daily memory behind More local context")
        XCTAssertTrue(textWithContent("Highlights").firstMatch.exists,
                      "digest highlights hierarchy is missing")
        XCTAssertTrue(textWithContent("Tasks").firstMatch.exists,
                      "digest task hierarchy is missing")
        XCTAssertTrue(textWithContent("Updated the Timeline UI").firstMatch.exists,
                      "human-facing focus summary is missing")
        XCTAssertFalse(textWithContent("User updated the Timeline UI").firstMatch.exists,
                       "model bookkeeping subject leaked into the focus summary")
        XCTAssertFalse(textWithContent("screen:4242").firstMatch.exists,
                       "private evidence identifier leaked into Today")
        XCTAssertFalse(textWithContent("Time allocation").firstMatch.exists,
                       "Today repeated its app-time chart inside the digest")
        XCTAssertFalse(app.descendants(matching: .any)["dayDigest.fullActivityLog"].exists,
                       "Today exposed the forensic activity log")
    }

    // MARK: - Library

    /// LokalBot owns one split-view sidebar toggle so every navigation topology
    /// shares the same explicit visibility state. Count every sidebar control,
    /// not just the app-owned identifier — NavigationSplitView's generated
    /// toggle carries its own identity and must not ride along, in either
    /// sidebar state.
    func testToolbarShowsOneSidebarToggle() {
        XCTAssertTrue(toolbarSidebarButtons.firstMatch.waitForExistence(timeout: 4),
                      "app-owned sidebar toolbar control missing")
        XCTAssertEqual(anySidebarToggleButtons.count, 1,
                       "toolbar should contain exactly one sidebar control while the sidebar is visible")

        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(UITestHarness.waitUntil {
            !self.app.descendants(matching: .any)["sidebar.settings"].exists
        }, "sidebar remained exposed after hiding it")
        XCTAssertEqual(anySidebarToggleButtons.count, 1,
                       "toolbar should contain exactly one sidebar control while the sidebar is hidden")

        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["sidebar.settings"]
            .waitForExistence(timeout: 5), "sidebar did not return")
    }

    /// The native toolbar item must do real work in both directions. This
    /// guards the recent split-view stabilization against a control that is
    /// present but detached from NavigationSplitView's column visibility.
    func testToolbarToggleHidesAndRestoresSidebar() {
        XCTAssertTrue(toolbarSidebarButtons.firstMatch.waitForExistence(timeout: 4),
                      "native sidebar control missing")
        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(UITestHarness.waitUntil {
            !self.app.descendants(matching: .any)["sidebar.settings"].exists
        }, "sidebar remained exposed after hiding it")

        XCTAssertTrue(toolbarSidebarButtons.firstMatch.waitForExistence(timeout: 4),
                      "sidebar control disappeared after hiding")
        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["sidebar.timeline"]
            .waitForExistence(timeout: 5), "sidebar did not return")
    }

    /// Query the app-owned identifier among direct toolbar children so nested
    /// accessibility wrappers cannot inflate the count.
    private var toolbarSidebarButtons: XCUIElementQuery {
        app.toolbars.firstMatch.children(matching: .button).matching(NSPredicate(
            format: "identifier == 'toolbar.sidebarToggle'"))
    }

    /// Any sidebar toggle among direct toolbar children, app-owned or
    /// system-generated (the generated item has no app identifier, only a
    /// "Hide/Show Sidebar" label).
    private var anySidebarToggleButtons: XCUIElementQuery {
        app.toolbars.firstMatch.children(matching: .button).matching(NSPredicate(
            format: "identifier == 'toolbar.sidebarToggle' OR label CONTAINS[c] 'sidebar'"))
    }

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

    func testMeetingLibrarySearchAndStatusFilterRender() {
        openLibrary()
        let search = app.textFields["meeting.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 4), "meeting search missing")
        XCTAssertTrue(app.descendants(matching: .any)["meeting.statusFilter"].exists,
                      "status filter missing")
        search.click()
        search.typeText("Q3 roadmap")
        XCTAssertTrue(meetingRow(for: fixture.planning).waitForExistence(timeout: 4))
        XCTAssertFalse(meetingRow(for: fixture.designReview).exists)
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
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

        clickSidebar("sidebar.timeline")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 4),
                      "timeline section did not come back")
    }

    func testSidebarUsesApprovedRememberAndWriteActHierarchy() {
        XCTAssertTrue(identified("sidebar.section.remember").exists)
        XCTAssertTrue(identified("sidebar.section.writeAct").exists)
        let ordered = ["sidebar.today", "sidebar.timeline", "sidebar.meetings",
                       "sidebar.ask", "sidebar.type", "sidebar.agent", "sidebar.settings"]
            .map { app.staticTexts[$0] }
        for item in ordered {
            XCTAssertTrue(item.exists, "approved sidebar destination missing")
        }
        for pair in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(pair.0.frame.midY, pair.1.frame.midY,
                              "approved sidebar order changed")
        }
        // The footer is state-aware: these strings are the local-default
        // posture (test host uses built-in Think). With an approved remote
        // backend it switches to the "Think uses an approved remote server"
        // wording — covered by AppSettingsTests.usesRemoteMainLLM.
        XCTAssertTrue(textWithContent("All memory is local").firstMatch.exists)
        XCTAssertTrue(textWithContent("No data leaves your Mac").firstMatch.exists)
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
        XCTAssertTrue(app.descendants(matching: .any)["models.readiness"]
            .waitForExistence(timeout: 6), "core readiness overview missing")
        XCTAssertTrue(app.descendants(matching: .any)["models.storage"].exists,
                      "model storage summary missing")
        XCTAssertTrue(textWithContent("Core roles").firstMatch.exists)
        openAdvancedModelDetails()
        XCTAssertTrue(app.buttons["models.stack.change.transcribe"]
            .waitForExistence(timeout: 6),
                      "Models pane did not render the Your stack card")
        XCTAssertTrue(app.descendants(matching: .any)["models.dictationComposition"].exists,
                      "dictation composition model card identifier missing")
        XCTAssertTrue(app.descendants(matching: .any)["models.embeddings"].exists,
                      "embeddings model card identifier missing")

        for (change, card) in [("models.stack.change.transcribe", "models.transcription"),
                               ("models.stack.change.think", "models.summarization"),
                               ("models.stack.change.type", "models.cotyping")] {
            let button = app.buttons[change]
            XCTAssertTrue(button.waitForExistence(timeout: 4), "\(change) button missing")
            UITestHarness.scrollTo(button, in: app)
            button.click()
            XCTAssertTrue(app.descendants(matching: .any)[card]
                .waitForExistence(timeout: 4),
                          "\(card) did not expand from its Change button")
        }
    }

    func testModelsCanOpenCustomGraniteSpeechPicker() {
        clickSidebar("sidebar.settings")
        let tabs = app.descendants(matching: .any)["settings.tab"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 8), "settings tab strip missing")
        let segment = tabs.buttons["Models"].exists
            ? tabs.buttons["Models"] : tabs.radioButtons["Models"]
        XCTAssertTrue(segment.waitForExistence(timeout: 4), "Models segment missing")
        segment.click()
        openAdvancedModelDetails()

        let change = app.buttons["models.stack.change.transcribe"]
        XCTAssertTrue(change.waitForExistence(timeout: 6), "Transcribe Change button missing")
        change.click()

        let customize = app.buttons["models.granite.customize"]
        UITestHarness.scrollTo(customize, in: app, attempts: 4)
        XCTAssertTrue(customize.waitForExistence(timeout: 4),
                      "custom Granite model button missing")
        customize.click()

        XCTAssertTrue(app.staticTexts["models.granite.picker.title"]
            .waitForExistence(timeout: 5), "custom Granite picker did not open")
        XCTAssertTrue(app.textFields["models.granite.repository"].exists,
                      "Hugging Face repository field missing")
        XCTAssertTrue(app.buttons["Use selected model"].exists,
                      "custom-model confirmation action missing")
    }

    func testModelPresetRequiresReviewBeforeApplying() {
        clickSidebar("sidebar.settings")
        let tabs = app.descendants(matching: .any)["settings.tab"]
        let segment = tabs.buttons["Models"].exists
            ? tabs.buttons["Models"] : tabs.radioButtons["Models"]
        XCTAssertTrue(segment.waitForExistence(timeout: 6))
        segment.click()

        let preset = app.buttons["models.preset.lightweight"]
        UITestHarness.scrollTo(preset, in: app)
        XCTAssertTrue(preset.waitForExistence(timeout: 5), "Lightweight preset missing")
        preset.click()
        XCTAssertTrue(app.buttons["Apply and stage downloads"]
            .waitForExistence(timeout: 4), "preset applied without a review step")
        XCTAssertTrue(textWithContent("Estimated new download").firstMatch.exists)
        let reviewSheet = app.sheets.firstMatch
        XCTAssertTrue(reviewSheet.waitForExistence(timeout: 4), "preset review sheet missing")
        reviewSheet.buttons["Cancel"].firstMatch.click()
    }

    // MARK: - Timeline

    /// Timeline is one day explorer: its persistent header and work sessions
    /// stay put while a bounded panel swaps between the day brief, session, and
    /// meeting previews.
    func testTimelineRendersTrackAndOverview() {
        clickSidebar("sidebar.timeline")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 6), "persistent day header did not render")
        XCTAssertTrue(identified("capture.askDay").exists,
                      "persistent Timeline actions did not render")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.workSessions"]
            .waitForExistence(timeout: 6), "work sessions should be visible immediately")
        XCTAssertTrue(app.descendants(matching: .any)["capture.dayOverview"]
            .waitForExistence(timeout: 6), "day brief did not render beside the track")
        XCTAssertLessThan(
            app.descendants(matching: .any)["capture.dayOverview"].firstMatch.frame.midX,
            app.descendants(matching: .any)["timeline.workSessions"].firstMatch.frame.midX,
            "Day brief should be left of Work sessions in the wide Timeline layout")
        XCTAssertTrue(identified("timeline.dayDigest.generate").waitForExistence(timeout: 5),
                      "day-digest action should remain directly visible")
        XCTAssertFalse(identified("timeline.activityEvidence").exists,
                       "the chronological track should not be hidden behind Activity evidence")
        XCTAssertFalse(textWithContent("Needs attention").firstMatch.exists,
                       "empty outcome card should not consume Timeline space")
        XCTAssertFalse(textWithContent("Decisions").firstMatch.exists,
                       "empty decisions section should not consume Timeline space")
        XCTAssertTrue(textWithContent("Time allocation").firstMatch.waitForExistence(timeout: 6),
                      "compact time allocation missing — seeded activity did not load")
        XCTAssertTrue(textWithContent("Xcode").firstMatch.exists,
                      "seeded activity app 'Xcode' missing from Timeline")
        XCTAssertTrue(textWithContent("Tasks").firstMatch.exists,
                      "digest task hierarchy is missing")
        XCTAssertTrue(textWithContent("Updated the Timeline UI").firstMatch.exists,
                      "human-facing focus summary is missing")
        XCTAssertFalse(textWithContent("User updated the Timeline UI").firstMatch.exists,
                       "model bookkeeping subject leaked into the focus summary")
        XCTAssertFalse(textWithContent("screen:4242").firstMatch.exists,
                       "private evidence identifier leaked into the collapsed overview")
        XCTAssertFalse(textWithContent("No activity recorded").firstMatch.exists,
                       "empty state shown despite seeded activity blocks")
        // The grounded block title becomes the human-scale session title.
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "TimelineView.swift"))
            .firstMatch.exists,
                      "seeded work-session title missing")
        // Meetings remain first-class chronological rows.
        XCTAssertTrue(app.descendants(matching: .any)["capture.meeting.\(fixture.designReview.id.uuidString)"].exists,
                      "seeded meeting missing from Work sessions")
        let rawCapture = app.buttons["timeline.rawCapture"]
        XCTAssertTrue(rawCapture.exists,
                      "raw capture disclosure is missing")
        XCTAssertFalse(app.descendants(matching: .any)["timeline.track"].exists,
                       "raw block chart should not be the default Timeline presentation")
        rawCapture.click()
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"]
            .waitForExistence(timeout: 4), "raw block chart did not expand on request")
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "capture.activity."))
            .firstMatch.exists, "raw activity blocks are no longer inspectable")
        // The four-tab inspector is gone.
        XCTAssertFalse(app.descendants(matching: .any)["timeline.inspector"].exists,
                       "legacy inspector segmented control should be removed")
    }

    func testTimelineSelectionOnlyReplacesBoundedContext() {
        clickSidebar("sidebar.timeline")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.workSessions"]
            .waitForExistence(timeout: 6))

        let session = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "timeline.session."))
            .firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 4),
                      "work sessions must be keyboard-focusable buttons")
        session.click()
        XCTAssertTrue(app.descendants(matching: .any)["timeline.sessionPreview"]
            .waitForExistence(timeout: 4), "session preview did not replace the day brief")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"].exists,
                      "session selection replaced the persistent day header")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.workSessions"].exists,
                      "session selection replaced the session list")
        XCTAssertTrue(textWithContent("Representative evidence").firstMatch.exists,
                      "session preview does not explain its evidence")

        let back = app.buttons["Back to day digest"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.click()
        XCTAssertTrue(app.descendants(matching: .any)["capture.dayOverview"]
            .waitForExistence(timeout: 3))

        let meeting = app.buttons["capture.meeting.\(fixture.designReview.id.uuidString)"]
        XCTAssertTrue(meeting.waitForExistence(timeout: 4),
                      "meeting block is not an accessible Timeline button")
        meeting.click()
        XCTAssertTrue(app.descendants(matching: .any)["timeline.meetingPreview"]
            .waitForExistence(timeout: 4), "Timeline did not open its compact meeting preview")
        XCTAssertFalse(app.descendants(matching: .any)["meeting.detail.workspace"].exists,
                       "Timeline mounted the full Meetings workspace")
        XCTAssertTrue(app.buttons["Open meeting"].exists,
                      "compact preview must provide the explicit Meetings handoff")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.workSessions"].exists,
                      "meeting selection replaced Work sessions")
    }

    /// A date change is one state transition for the whole day workspace: it
    /// clears an old meeting preview and swaps the cached track, brief, and
    /// persisted digest to the newly selected local calendar day.
    func testTimelineDateChangeRefreshesOverviewAndDigest() {
        openLibrary()
        selectMeeting(fixture.designReview)
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 4),
                      "meeting detail did not open before changing the day")

        clickSidebar("sidebar.timeline")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 6), "Timeline did not render")

        let previousDay = app.buttons["timeline.previousDay"]
        XCTAssertTrue(previousDay.waitForExistence(timeout: 4),
                      "previous-day control is missing")
        previousDay.click()

        XCTAssertTrue(app.descendants(matching: .any)["capture.dayOverview"]
            .waitForExistence(timeout: 6),
                      "old meeting selection kept the new day's overview hidden")
        XCTAssertTrue(textWithContent(SyntheticFixture.previousDayDigestMarker).firstMatch
            .waitForExistence(timeout: 4), "previous day's digest did not replace today's")
        XCTAssertFalse(textWithContent(SyntheticFixture.todayDigestMarker).firstMatch.exists,
                       "today's digest remained visible after changing the date")
        XCTAssertFalse(textWithContent("Time allocation").firstMatch.exists,
                       "today's activity totals remained in the previous-day overview")
    }

    /// The sidebar swaps the content column between Timeline (work sessions)
    /// and Meetings (grouped meeting list) both ways.
    func testSidebarTogglesBetweenTimelineAndMeetings() {
        clickSidebar("sidebar.timeline")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 6), "Timeline workspace missing")

        openLibrary()
        XCTAssertFalse(app.descendants(matching: .any)["timeline.dayPicker"].exists,
                       "Timeline should leave the screen in Meetings")

        clickSidebar("sidebar.timeline")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 4), "Timeline did not come back")
    }

    // MARK: - Detail tabs

    func testMeetingRowOpensOutcomePreviewBeforeFullWorkspace() {
        openLibrary()
        let row = meetingRow(for: fixture.designReview)
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        row.click()
        XCTAssertTrue(app.descendants(matching: .any)["meeting.preview"]
            .waitForExistence(timeout: 5), "row did not open the selected-meeting preview")
        XCTAssertTrue(textWithContent("My actions").firstMatch.exists)
        XCTAssertTrue(app.buttons["Open meeting"].exists)
    }

    func testActionCompletionImmediatelyLeavesTodayAttention() {
        openLibrary()
        let row = meetingRow(for: fixture.designReview)
        row.click()
        let toggle = app.buttons["meeting.preview.action.toggle.fixture-action-design-1"]
        UITestHarness.scrollTo(toggle, in: app, attempts: 8)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "preview action toggle missing")
        toggle.click()

        clickSidebar("sidebar.today")
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 5))
        XCTAssertFalse(textWithContent("Draft the eviction policy document").firstMatch.exists,
                       "completed action remained in Today attention")
    }

    /// Full detail leads with actions/decisions/follow-up; source summary and
    /// transcript remain available behind explicit evidence disclosures.
    func testMeetingDetailTabsLoadSummaryAndTranscript() {
        openLibrary()
        selectMeeting(fixture.designReview)

        let title = app.staticTexts["detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        // SwiftUI `Text` puts the rendered string in AXValue, not AXLabel.
        XCTAssertEqual(title.value as? String, fixture.designReview.title)

        XCTAssertTrue(textWithContent("Action items").firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(textWithContent("Adopt Redis").firstMatch.exists,
                      "cited decision text missing")
        XCTAssertTrue(textWithContent("Follow-up").firstMatch.exists)

        let summaryDisclosure = identified("meeting.summaryDisclosure")
        UITestHarness.scrollTo(summaryDisclosure, in: app)
        XCTAssertTrue(summaryDisclosure.waitForExistence(timeout: 4),
                      "summary disclosure missing")
        summaryDisclosure.coordinate(
            withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
        XCTAssertTrue(textWithContent("TL;DR").firstMatch.waitForExistence(timeout: 4),
                      "summary evidence did not expand")

        let transcriptDisclosure = identified("meeting.transcriptDisclosure")
        UITestHarness.scrollTo(transcriptDisclosure, in: app)
        XCTAssertTrue(transcriptDisclosure.waitForExistence(timeout: 4))
        transcriptDisclosure.coordinate(
            withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
        XCTAssertTrue(textWithContent("eviction policy").firstMatch
            .waitForExistence(timeout: 3),
                      "transcript segment text missing")
        let firstSegment = identified("transcript.segment.0")
        XCTAssertTrue(firstSegment.waitForExistence(timeout: 3),
                      "speaker chip 'Me' missing on transcript")
        XCTAssertTrue(firstSegment.label.hasPrefix("Me,"),
                      "first transcript speaker was not identified as Me")
    }

    /// Secondary processing and export controls live in the approved overflow.
    func testMeetingProcessingActionsAreDirectToolbarButtons() {
        openLibrary()
        selectMeeting(fixture.designReview)
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 4),
                      "meeting detail did not open")

        let toolbar = app.toolbars.firstMatch
        for identifier in ["toolbar.transcribeAndSummarize",
                           "toolbar.transcribeOnly",
                           "toolbar.resummarize"] {
            XCTAssertFalse(toolbar.children(matching: .button)[identifier].exists,
                           "\(identifier) should have moved into overflow")
        }
        let more = identified("meeting.more")
        XCTAssertTrue(more.waitForExistence(timeout: 4), "meeting overflow missing")
        more.click()
        XCTAssertTrue(app.menuItems["Transcribe and summarize"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Re-summarize"].exists)
        XCTAssertTrue(app.menuItems["Export audio"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Ask

    /// FTS5-backed search reindexes on every launch — typing a term that
    /// only appears in the synthetic transcripts surfaces the matching
    /// meeting, and clicking the hit deep-links to that meeting's detail.
    func testSearchFindsTranscriptHitAndDeepLinks() {
        clickSidebar("sidebar.ask")
        switchToKeywordSearch()

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
        XCTAssertTrue(app.descendants(matching: .any)["ask.submit"].exists,
                      "explicit Ask action missing")
        for source in ["meetings", "today", "screen"] {
            XCTAssertTrue(app.descendants(matching: .any)["ask.source.\(source)"].exists,
                          "per-question \(source) source missing")
        }
        XCTAssertTrue(app.descendants(matching: .any)["ask.semantic"].exists,
                      "Match by meaning control missing")

        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 4), "ask input field missing")
        let layoutDeadline = Date().addingTimeInterval(4)
        while field.frame.width < 40, Date() < layoutDeadline { usleep(150_000) }
        field.click()
        field.typeText("what did we decide")
        XCTAssertEqual(field.value as? String, "what did we decide",
                       "ask input did not accept typed text")

        XCTAssertTrue(app.buttons["ask.submit"].isEnabled,
                      "Ask action did not become available for the typed question")
    }

    func testAskSwitchesExplicitlyToKeywordSearch() {
        clickSidebar("sidebar.ask")
        let keyword = app.buttons["Keyword search"]
        XCTAssertTrue(keyword.waitForExistence(timeout: 5), "Keyword search mode missing")
        keyword.click()
        XCTAssertTrue(textWithContent("Keyword search").firstMatch.waitForExistence(timeout: 4))
        // One segmented control owns all three retrieval modes, so Ask and
        // Match by meaning stay one click away instead of a "Back" round trip.
        XCTAssertTrue(identified("ask.mode.ask").exists, "Ask segment missing")
        XCTAssertTrue(identified("ask.semantic").exists, "Match by meaning segment missing")
        XCTAssertFalse(app.descendants(matching: .any)["ask.source.meetings"].exists,
                       "Ask scopes should not masquerade as keyword facets")
    }

    /// Restored split widths from Timeline or Meetings must not let the
    /// conversation list consume the Ask workspace. Push the detail divider
    /// toward the window edge and verify both column constraints hold.
    func testAskDetailResistsConversationListSqueeze() {
        clickSidebar("sidebar.ask")

        let field = app.textFields["search.field"]
        let conversations = app.outlines["chat.conversationList"]
        XCTAssertTrue(field.waitForExistence(timeout: 6), "ask input field missing")
        XCTAssertTrue(conversations.waitForExistence(timeout: 6),
                      "conversation list missing")

        let splitters = app.splitters
        XCTAssertGreaterThanOrEqual(splitters.count, 2,
                                    "Ask should expose sidebar and detail dividers")
        let detailDivider = splitters.element(boundBy: 1)
        XCTAssertTrue(detailDivider.waitForExistence(timeout: 4),
                      "Ask detail divider missing")

        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 3)
        let destination = app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        detailDivider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: destination)

        XCTAssertTrue(UITestHarness.waitUntil {
            let detailWidth = self.app.windows.firstMatch.frame.maxX
                - detailDivider.frame.maxX
            return conversations.frame.width <= 330 && detailWidth >= 420
        }, "conversation history squeezed Ask below its readable width "
           + "(history: \(conversations.frame.width), Ask field: \(field.frame.width))")
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
        XCTAssertTrue(textWithContent("Press Delete or use the list menu").firstMatch.exists,
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

    // MARK: - Settings

    /// ⌘, must land on the one in-window Settings home — the separate
    /// macOS Settings scene is gone (spec: one home per concern).
    func testSettingsShortcutLandsInWindow() {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["settings.form"]
            .waitForExistence(timeout: 6),
                      "⌘, did not open Settings in the main window")
    }

    // MARK: - Helpers

    /// Click a sidebar entry by accessibility identifier. The identifier
    /// lives on the inner `Label`; descend-by-id is unambiguous because
    /// each sidebar item carries a unique identifier (`sidebar.<section>`).
    private func clickSidebar(_ identifier: String) {
        UITestHarness.clickSidebar(identifier, in: app)
    }

    /// Open the Meetings section and wait for the meeting list —
    /// the precondition for every list/detail/delete test.
    private func openLibrary() {
        clickSidebar("sidebar.meetings")
        XCTAssertTrue(app.outlines["meeting.list"].waitForExistence(timeout: 6),
                      "meeting list did not render in Meetings")
    }

    private func openAdvancedModelDetails() {
        let disclosure = identified("models.advanced")
        UITestHarness.scrollTo(disclosure, in: app, attempts: 8)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5),
                      "Advanced model details disclosure missing")
        disclosure.coordinate(
            withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
    }

    private func selectMeeting(_ meeting: SyntheticFixture.Meeting) {
        let row = meetingRow(for: meeting)
        XCTAssertTrue(row.waitForExistence(timeout: 4),
                      "meeting row for \(meeting.title) not found")
        row.click()
        XCTAssertTrue(app.descendants(matching: .any)["meeting.preview"]
            .waitForExistence(timeout: 4), "meeting preview did not render")
        let open = app.buttons["Open meeting"]
        XCTAssertTrue(open.waitForExistence(timeout: 4), "Open meeting action missing")
        open.click()
        XCTAssertTrue(app.descendants(matching: .any)["meeting.detail.workspace"]
            .waitForExistence(timeout: 5), "full meeting workspace did not render")
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

    private func identified(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    private func switchToKeywordSearch() {
        let keyword = app.buttons["Keyword search"]
        XCTAssertTrue(keyword.waitForExistence(timeout: 5), "Keyword search mode missing")
        keyword.click()
        XCTAssertTrue(UITestHarness.waitUntil { keyword.isSelected },
                      "Ask did not enter keyword-search mode")
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
