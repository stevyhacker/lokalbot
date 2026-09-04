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
        let launch = try UITestHarness.launch(
            storageRoot: fixture.root,
            suitePrefix: "MainWindow",
            environment: ["LOKALBOT_UI_TEST_DIAGNOSTICS": "1"])
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
        XCTAssertTrue(identified("today.dayDigest.actions").exists,
                      "Today should expose copy and Markdown export actions")
        XCTAssertFalse(identified("today.moreLocalContext").exists,
                       "Today should not hide its daily memory behind More local context")
        XCTAssertTrue(textWithContent("Highlights").firstMatch.exists,
                      "digest highlights hierarchy is missing")
        XCTAssertTrue(digestTasksVisible(),
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

    /// The command palette uses one AppKit field-editor path. A printable key
    /// must update its query exactly once rather than also travelling through
    /// the palette's navigation-key handler.
    func testCommandPaletteDoesNotDuplicateTypedCharacters() {
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["palette.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 4), "command palette input missing")

        field.click()
        field.typeText("AI tooling")

        XCTAssertEqual(field.value as? String, "AI tooling")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// The native toolbar item must do real work in both directions. This
    /// guards the recent split-view stabilization against a control that is
    /// present but detached from NavigationSplitView's column visibility.
    func testToolbarToggleHidesAndRestoresSidebar() {
        clickSidebar("sidebar.timeline")
        XCTAssertTrue(identified("timeline.dayPicker").waitForExistence(timeout: 5),
                      "Timeline did not render before the sidebar toggle check")
        XCTAssertTrue(toolbarSidebarButtons.firstMatch.waitForExistence(timeout: 4),
                      "native sidebar control missing")
        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(UITestHarness.waitUntil {
            !self.app.descendants(matching: .any)["sidebar.settings"].exists
        }, "sidebar remained exposed after hiding it")

        XCTAssertTrue(toolbarSidebarButtons.firstMatch.waitForExistence(timeout: 4),
                      "sidebar control disappeared after hiding")
        toolbarSidebarButtons.firstMatch.click()
        let timeline = app.descendants(matching: .any)["sidebar.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5), "sidebar did not return")

        let window = app.windows.firstMatch
        let privacyFooter = identified("sidebar.localPrivacy")
        XCTAssertTrue(privacyFooter.waitForExistence(timeout: 3),
                      "sidebar footer did not return")
        XCTAssertLessThan(abs(privacyFooter.frame.minX - window.frame.minX), 4,
                          "restored sidebar left an empty column at the window edge")
    }

    func testToolbarToggleWorksInThreeColumnSection() {
        clickSidebar("sidebar.ask")
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 6),
                      "Ask did not render before the sidebar toggle check")

        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(UITestHarness.waitUntil {
            !self.app.descendants(matching: .any)["sidebar.settings"].exists
        }, "three-column sidebar remained exposed after hiding it")

        XCTAssertTrue(toolbarSidebarButtons.firstMatch.waitForExistence(timeout: 4),
                      "three-column sidebar control disappeared after hiding")
        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["sidebar.ask"]
            .waitForExistence(timeout: 5), "three-column sidebar did not return")

        let privacyFooter = identified("sidebar.localPrivacy")
        XCTAssertLessThan(abs(privacyFooter.frame.minX - app.windows.firstMatch.frame.minX), 4,
                          "three-column sidebar restored with an empty leading column")
    }

    /// The sidebar content must stay attached to the window edge even when
    /// AppKit restores or accepts an oversized first split column. A fixed-
    /// width child centered in that column creates the blank gutters this
    /// test is intended to prevent.
    func testSidebarStaysAtLeadingEdgeAfterColumnResizeAndToggle() {
        clickSidebar("sidebar.meetings")
        XCTAssertTrue(app.outlines["meeting.list"].waitForExistence(timeout: 6),
                      "Meetings did not render before the sidebar resize check")

        let window = app.windows.firstMatch
        let sidebarDivider = app.splitters.element(boundBy: 0)
        let privacyFooter = identified("sidebar.localPrivacy")
        XCTAssertTrue(sidebarDivider.waitForExistence(timeout: 4),
                      "sidebar divider missing")
        XCTAssertTrue(privacyFooter.waitForExistence(timeout: 4),
                      "sidebar footer missing")

        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 3)
        let destination = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        sidebarDivider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: destination)

        XCTAssertLessThan(abs(privacyFooter.frame.minX - window.frame.minX), 4,
                          "resizing centered the sidebar inside an oversized column")

        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(UITestHarness.waitUntil {
            !self.app.descendants(matching: .any)["sidebar.settings"].exists
        }, "resized sidebar remained exposed after hiding it")
        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(privacyFooter.waitForExistence(timeout: 5),
                      "resized sidebar did not return")
        XCTAssertLessThan(abs(privacyFooter.frame.minX - window.frame.minX), 4,
                          "restored resized sidebar detached from the window edge")
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
        XCTAssertFalse(app.buttons["sidebar.section.remember"].exists,
                       "Remember must be a header, not a destination")
        XCTAssertFalse(app.buttons["sidebar.section.writeAct"].exists,
                       "Write & Act must be a header, not a destination")
        let ordered = ["sidebar.today", "sidebar.timeline", "sidebar.meetings",
                       "sidebar.ask", "sidebar.type", "sidebar.agent", "sidebar.settings"]
            .map(identified)
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
        XCTAssertFalse(app.buttons["models.advanced"].exists,
                       "Models should not hide configuration behind Advanced details")
        XCTAssertTrue(app.buttons["models.stack.change.transcribe"]
            .waitForExistence(timeout: 6),
                      "Core Transcribe row did not render its Change button")
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
        let usesContextDrawer = revealTimelineContext()
        if !usesContextDrawer {
            XCTAssertLessThan(
                identified("capture.dayOverview").frame.midX,
                identified("timeline.workSessions").frame.midX,
                "Day brief should be left of Work sessions in the wide Timeline layout")
        }
        XCTAssertTrue(identified("timeline.dayDigest.generate").waitForExistence(timeout: 5),
                      "day-digest action should remain directly visible")
        XCTAssertTrue(identified("timeline.dayDigest.actions").exists,
                      "Timeline should expose copy and Markdown export actions")
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
        XCTAssertTrue(digestTasksVisible(),
                      "digest task hierarchy is missing")
        XCTAssertTrue(textWithContent("Updated the Timeline UI").firstMatch.exists,
                      "human-facing focus summary is missing")
        XCTAssertFalse(textWithContent("User updated the Timeline UI").firstMatch.exists,
                       "model bookkeeping subject leaked into the focus summary")
        XCTAssertFalse(textWithContent("screen:4242").firstMatch.exists,
                       "private evidence identifier leaked into the collapsed overview")
        XCTAssertFalse(textWithContent("No activity recorded").firstMatch.exists,
                       "empty state shown despite seeded activity blocks")
        if usesContextDrawer { closeTimelineContext() }
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
        closeTimelineContext()

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

        _ = revealTimelineContext()
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

    func testMeetingRowOpensFullWorkspaceWithAudioPlayer() {
        openLibrary()
        let row = meetingRow(for: fixture.designReview)
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        row.click()
        XCTAssertTrue(app.descendants(matching: .any)["meeting.detail.workspace"]
            .waitForExistence(timeout: 5), "row did not open the full meeting workspace")
        XCTAssertTrue(identified("meeting.audioPlayer").waitForExistence(timeout: 5),
                      "full meeting workspace did not expose recorded-audio playback")
        XCTAssertFalse(app.buttons["Open meeting"].exists,
                       "meeting selection should not require a second navigation step")
        let actions = identified("toolbar.meetingActions")
        XCTAssertTrue(actions.exists, "full workspace should retain meeting copy/export actions")
        actions.click()
        XCTAssertTrue(app.menuItems["Copy Meeting as Markdown"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Export Meeting as Markdown..."].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testActionCompletionImmediatelyLeavesTodayAttention() {
        openLibrary()
        let row = meetingRow(for: fixture.designReview)
        row.click()
        let toggle = app.buttons["meeting.action.toggle.fixture-action-design-1"]
        UITestHarness.scrollTo(toggle, in: app, attempts: 8)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "meeting action toggle missing")
        toggle.click()

        clickSidebar("sidebar.today")
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 5))
        XCTAssertFalse(textWithContent("Draft the eviction policy document").firstMatch.exists,
                       "completed action remained in Today attention")
    }

    func testMultiMeetingThreadCompletionRequiresConfirmation() throws {
        try relaunchWithMatchingActions()
        let toggle = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "outcome.thread.toggle.")).firstMatch
        UITestHarness.scrollTo(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        let confirm = app.buttons["Mark all done"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4), "Multi-meeting completion needs explicit approval")
        app.buttons["Cancel"].firstMatch.click()
        let stateURLs = [fixture.designReview, fixture.standup].map {
            fixture.folder(for: $0).appendingPathComponent("outcome-state.json")
        }
        XCTAssertTrue(stateURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
                      "Cancelling must not write either source overlay")
        toggle.click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 4))
        confirm.click()
        XCTAssertTrue(UITestHarness.waitUntil {
            stateURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        })
        for url in stateURLs {
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let saved = try XCTUnwrap(state["actions"] as? [String: [String: Any]])
            XCTAssertEqual(saved["fixture-action-design-1"]?["status"] as? String, "done")
        }
    }

    func testActionThreadSourceCanBeSeparatedAndRestored() throws {
        try relaunchWithMatchingActions()
        let sources = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "outcome.thread.sources.")).firstMatch
        UITestHarness.scrollTo(sources, in: app)
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        sources.click()
        let separate = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "outcome.thread.separate.")).firstMatch
        XCTAssertTrue(separate.waitForExistence(timeout: 4))
        separate.click()
        let stateURLs = [fixture.designReview, fixture.standup].map {
            fixture.folder(for: $0).appendingPathComponent("outcome-state.json")
        }
        XCTAssertTrue(UITestHarness.waitUntil {
            stateURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 1
        })
        let stateURL = try XCTUnwrap(stateURLs.first { FileManager.default.fileExists(atPath: $0.path) })
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let actions = try XCTUnwrap(state["actions"] as? [String: [String: Any]])
        XCTAssertEqual(actions["fixture-action-design-1"]?["isThreadExcluded"] as? Bool, true)
        let toggles = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "outcome.thread.toggle."))
        XCTAssertTrue(UITestHarness.waitUntil { toggles.count == 2 })
        let menus = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "outcome.thread.status."))
        var restored = false
        for index in 0..<menus.count {
            menus.element(boundBy: index).click()
            let restore = app.menuItems["Allow matching across meetings"]
            if restore.waitForExistence(timeout: 1) {
                restore.click()
                restored = true
                break
            }
            app.typeKey(.escape, modifierFlags: [])
        }
        XCTAssertTrue(restored)
        XCTAssertTrue(UITestHarness.waitUntil { toggles.count == 1 })
    }

    private func relaunchWithMatchingActions() throws {
        app.terminate()
        let source = fixture.folder(for: fixture.designReview).appendingPathComponent("outcomes.json")
        let target = fixture.folder(for: fixture.standup).appendingPathComponent("outcomes.json")
        var outcomes = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        let actions = try XCTUnwrap(outcomes["actionItems"] as? [[String: Any]])
        outcomes["actionItems"] = [try XCTUnwrap(actions.first)]
        outcomes["decisionRecords"] = []
        outcomes["openQuestions"] = []
        try JSONSerialization.data(withJSONObject: outcomes).write(to: target, options: .atomic)
        app = try UITestHarness.relaunch(storageRoot: fixture.root,
                                        defaultsSuiteName: XCTUnwrap(defaultsSuiteName))
        XCTAssertTrue(identified("today.header").waitForExistence(timeout: 10))
    }

    /// Full detail leads with actions and decisions, keeps the summary visible,
    /// and retains the transcript as an explicit evidence disclosure.
    func testMeetingDetailLoadsExpandedSummaryAndTranscript() {
        openLibrary()
        selectMeeting(fixture.designReview)

        let title = app.staticTexts["detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        // SwiftUI `Text` puts the rendered string in AXValue, not AXLabel.
        XCTAssertEqual(title.value as? String, fixture.designReview.title)

        XCTAssertTrue(textWithContent("Action items").firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(textWithContent("Adopt Redis").firstMatch.exists,
                      "cited decision text missing")
        XCTAssertFalse(textWithContent("Follow-up").firstMatch.exists,
                       "meeting detail should not show the follow-up editor")

        let summarySection = identified("meeting.summary")
        UITestHarness.scrollTo(summarySection, in: app)
        XCTAssertTrue(summarySection.waitForExistence(timeout: 4),
                      "always-expanded summary section missing")
        XCTAssertFalse(identified("meeting.summaryDisclosure").exists,
                       "summary should not retain a disclosure control")
        XCTAssertTrue(textWithContent("TL;DR").firstMatch.waitForExistence(timeout: 4),
                      "summary content should be visible without expanding it")

        let transcriptDisclosure = identified("meeting.transcriptDisclosure")
        UITestHarness.scrollTo(transcriptDisclosure, in: app)
        XCTAssertTrue(transcriptDisclosure.waitForExistence(timeout: 4))
        transcriptDisclosure.coordinate(
            withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
        let firstSpeaker = app.buttons["transcript.segment.0.speaker"]
        UITestHarness.scrollTo(firstSpeaker, in: app)
        XCTAssertTrue(firstSpeaker.waitForExistence(timeout: 3),
                      "speaker rename control missing on transcript")
        XCTAssertTrue(firstSpeaker.label.contains("Me"),
                      "first transcript speaker was not identified as Me")
        let firstTranscriptText = app.staticTexts["transcript.segment.0.text"]
        XCTAssertTrue(firstTranscriptText.exists,
                      "transcript text must remain a selectable text element")
        XCTAssertTrue((firstTranscriptText.value as? String)?.contains("caching layer") == true,
                      "first transcript segment text missing")
    }

    /// Calendar attendees are explicit choices for remote diarization labels;
    /// email disambiguates the local choice but never becomes the alias.
    func testSpeakerRenameOffersCalendarAttendeeIdentities() {
        openLibrary()
        selectMeeting(fixture.designReview)

        let disclosure = identified("meeting.transcriptDisclosure")
        UITestHarness.scrollTo(disclosure, in: app)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 4))
        disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()

        let remoteSpeaker = app.buttons["transcript.segment.1.speaker"]
        UITestHarness.scrollTo(remoteSpeaker, in: app)
        XCTAssertTrue(remoteSpeaker.waitForExistence(timeout: 3))
        remoteSpeaker.click()

        let candidate = identified("speaker.rename.calendarCandidate.0")
        XCTAssertTrue(
            candidate.waitForExistence(timeout: 3),
            "calendar candidate missing from sheet AX tree:\n\(app.sheets.firstMatch.debugDescription)")
        XCTAssertEqual(
            candidate.elementType,
            .button,
            "calendar candidate must be an AXButton: \(candidate.debugDescription)")
        XCTAssertTrue(candidate.label.contains("Ana Petrović"),
                      "calendar candidate name missing from button label: \(candidate.label)")
        XCTAssertTrue(candidate.label.contains("ana@example.com"),
                      "calendar candidate email missing from button label: \(candidate.label)")
        candidate.click()

        let name = app.textFields["speaker.rename.name"]
        XCTAssertEqual(name.value as? String, "Ana Petrović")
        identified("speaker.rename.save").click()
        XCTAssertTrue(UITestHarness.waitUntil {
            self.app.buttons["transcript.segment.1.speaker"].label.contains("Ana Petrović")
        }, "calendar attendee was not saved as the speaker alias")
    }

    /// Frequent processing actions stay direct, while copy/export and speech
    /// utilities remain available in one clearly labelled overflow.
    func testMeetingProcessingActionsAreDirectToolbarButtons() {
        openLibrary()
        selectMeeting(fixture.designReview)
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 4),
                      "meeting detail did not open")

        let toolbar = app.toolbars.firstMatch
        for identifier in ["toolbar.transcribeAndSummarize",
                           "toolbar.transcribeOnly",
                           "toolbar.resummarize"] {
            XCTAssertTrue(toolbar.children(matching: .button)[identifier]
                .waitForExistence(timeout: 4), "\(identifier) should be directly visible")
        }
        let more = identified("toolbar.meetingActions")
        XCTAssertTrue(more.waitForExistence(timeout: 4), "meeting overflow missing")
        more.click()
        XCTAssertTrue(app.menuItems["Copy Summary"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Copy Transcript"].exists)
        XCTAssertTrue(app.menuItems["Copy Meeting as Markdown"].exists)
        XCTAssertTrue(app.menuItems["Export Meeting as Markdown..."].exists)
        XCTAssertTrue(app.menuItems["Export audio"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Command-F and the visible toolbar action search every visible meeting
    /// content node. Matches move through outcomes and summary prose into
    /// collapsed transcript evidence without switching to library-wide Ask.
    func testMeetingFindSearchesAllVisibleContent() {
        openLibrary()
        selectMeeting(fixture.designReview)
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 4))
        XCTAssertTrue(identified("toolbar.meetingSearch").exists)

        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["meeting.search.field"]
        XCTAssertTrue(
            field.waitForExistence(timeout: 3),
            "Command-F did not open meeting find. Menu tree:\n\(app.menuBars.debugDescription)")
        XCTAssertFalse(app.staticTexts["meeting.search.status"].exists,
                       "empty search repeated the field's scope label")
        field.typeText("failover")

        let status = app.staticTexts["meeting.search.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertEqual(status.value as? String, "1 of 4 · Action items")

        identified("meeting.search.next").click()
        identified("meeting.search.next").click()
        identified("meeting.search.next").click()
        XCTAssertEqual(status.value as? String, "4 of 4 · Transcript")
        XCTAssertTrue(app.staticTexts["transcript.segment.3.text"]
            .waitForExistence(timeout: 3), "transcript match did not expand its evidence")

        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Adopt Redis for caching")
        XCTAssertTrue(UITestHarness.waitUntil {
            status.value as? String == "1 of 2 · Decisions"
        }, "decision card text was not included before its summary duplicate")

        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Zoom")
        XCTAssertTrue(UITestHarness.waitUntil {
            status.value as? String == "1 of 1 · Meeting details"
        }, "meeting header metadata was not searchable")
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

        let segmentHit = identified(
            "search.hit.\(fixture.designReview.id.uuidString).segment")
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

        XCTAssertTrue(textWithContent("Ask your work memory").firstMatch
            .waitForExistence(timeout: 6),
                      "ask empty-state did not render")
        XCTAssertTrue(app.descendants(matching: .any)["ask.submit"].exists,
                      "explicit Ask action missing")
        XCTAssertTrue(identified("ask.sources").exists,
                      "per-question source menu missing")
        XCTAssertTrue(identified("ask.timeScope").exists,
                      "independent time-scope control missing")
        XCTAssertTrue(identified("ask.inferenceStatus").exists,
                      "local/remote inference status missing")
        XCTAssertTrue(askRetrievalSegment("Search").exists,
                      "Search mode missing")

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
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 6), "ask input field missing")
        let askFrame = field.frame

        UITestHarness.selectSegment(
            "Search", pickerIdentifier: "ask.retrieval", in: app)
        XCTAssertTrue(identified("ask.facet.all").waitForExistence(timeout: 4),
                      "Search facets did not appear")
        // The top-level switch stays binary; exact/meaning is a Search-only
        // menu so it cannot be confused with asking the model.
        XCTAssertTrue(askRetrievalSegment("Ask").exists, "Ask segment missing")
        XCTAssertTrue(identified("ask.searchMatching").exists,
                      "Exact/meaning search menu missing")
        XCTAssertFalse(identified("ask.sources").exists,
                       "Ask scopes should not masquerade as search facets")
        XCTAssertEqual(field.frame.minY, askFrame.minY, accuracy: 8,
                       "composer jumped vertically when leaving Ask")
        XCTAssertEqual(field.frame.minX, askFrame.minX, accuracy: 8,
                       "composer jumped horizontally when leaving Ask")
    }

    /// Restored split widths from Timeline or Meetings must not let the
    /// conversation list consume the Ask workspace. Push the detail divider
    /// toward the window edge and verify both column constraints hold.
    func testAskDetailResistsConversationListSqueeze() {
        clickSidebar("sidebar.ask")

        let field = app.textFields["search.field"]
        let conversations = identified("chat.conversationList")
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

    private func selectMeeting(_ meeting: SyntheticFixture.Meeting) {
        let row = meetingRow(for: meeting)
        XCTAssertTrue(row.waitForExistence(timeout: 4),
                      "meeting row for \(meeting.title) not found")
        row.click()
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

    /// Prefer the stable identifier; fall back to visible copy if AX role differs.
    private func digestTasksVisible() -> Bool {
        let identifiedHeader = app.descendants(matching: .any)["dayDigest.tasks"]
        if identifiedHeader.waitForExistence(timeout: 5) { return true }
        return textWithContent("Tasks").firstMatch.exists
    }

    private func switchToKeywordSearch() {
        UITestHarness.selectSegment(
            "Search", pickerIdentifier: "ask.retrieval", in: app)
        XCTAssertTrue(identified("ask.facet.all").waitForExistence(timeout: 5),
                      "Ask did not enter Search mode")
    }

    private func askRetrievalSegment(_ name: String) -> XCUIElement {
        UITestHarness.segment(name, pickerIdentifier: "ask.retrieval", in: app)
    }

    /// Timeline keeps the day context side by side when wide and behind an
    /// explicit drawer when narrow. Return whether the responsive drawer was
    /// needed so callers only make wide-layout frame assertions when valid.
    @discardableResult
    private func revealTimelineContext() -> Bool {
        let overview = identified("capture.dayOverview")
        let toggle = identified("timeline.context.toggle")
        let usesDrawer = toggle.exists
        if usesDrawer, !overview.exists { toggle.click() }
        XCTAssertTrue(overview.waitForExistence(timeout: 6),
                      "Timeline day context did not render")
        return usesDrawer
    }

    private func closeTimelineContext() {
        let overview = identified("capture.dayOverview")
        let toggle = identified("timeline.context.toggle")
        guard toggle.exists, overview.exists else { return }
        toggle.click()
        XCTAssertTrue(UITestHarness.waitUntil { !overview.exists },
                      "Timeline context drawer did not close")
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
