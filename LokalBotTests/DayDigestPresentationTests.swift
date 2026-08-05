import XCTest
@testable import LokalBot

final class DayDigestPresentationTests: XCTestCase {
    func testParsesHumanSummaryAndGroupsForensicLogByHour() {
        let markdown = """
            ## Day summary

            ### At a glance
            - Shipped a clearer digest presentation.
            - Verified the release build.

            ### Focus blocks
            - **09:00–10:15 · Digest redesign** — User implemented the parser [screen:11].
            - **13:05–14:20 · Verification** — Ran focused tests [screen:22] [screen:23].

            ### Decisions and next steps
            - Reinstall the signed app.

            ## Meetings

            ### 12:00 — Product sync
            - Outcome: use progressive disclosure.

            ## Time allocation

            | App | Tracked time |
            | --- | ---: |
            | Xcode | 1h 30m |
            | Safari | 25m |

            ## Full activity log

            - **09:00–09:45** — **Xcode** — DayDigestView.swift
              - [screen:11], 09:20: Structured the digest.
            - **09:45–10:15** — **Xcode** — Tests
            - **13:05** — **Screen context** — Safari — Documentation
              - [screen:22]: Read the API reference.
              - [screen:23]: Compared behavior.
            """

        let presentation = DayDigestPresentation(markdown: markdown)

        XCTAssertTrue(presentation.atAGlanceMarkdown.contains("clearer digest"))
        XCTAssertEqual(presentation.focusBlocks.count, 2)
        XCTAssertEqual(presentation.focusBlocks.map(\.sourceIDs), [[11], [22, 23]])
        XCTAssertEqual(presentation.focusBlocks.map(\.timeRange), ["09:00–10:15", "13:05–14:20"])
        XCTAssertEqual(presentation.focusBlocks.map(\.title), ["Digest redesign", "Verification"])
        XCTAssertEqual(presentation.focusBlocks.first?.summaryMarkdown,
                       "Implemented the parser.")
        XCTAssertFalse(presentation.focusBlocks.first?.summaryMarkdown.contains("screen:") == true)
        XCTAssertTrue(presentation.decisionsMarkdown?.contains("Reinstall") == true)
        XCTAssertTrue(presentation.meetingsMarkdown?.contains("Product sync") == true)
        XCTAssertEqual(presentation.timeAllocations.map(\.app), ["Xcode", "Safari"])
        XCTAssertEqual(presentation.timeAllocations.map(\.seconds), [5_400, 1_500])
        XCTAssertEqual(presentation.activityGroups.map(\.hour), ["09", "13"])
        XCTAssertEqual(presentation.activityGroups.map { $0.entries.count }, [2, 1])
        XCTAssertEqual(presentation.activityCount, 3)
        XCTAssertEqual(presentation.evidenceCount, 3)
    }

    func testLegacyHeadingsRemainReadableAndExtraSummaryMovesBehindDisclosure() {
        let bullets = (1...10).map { "- Legacy focus \($0)" }.joined(separator: "\n")
        let markdown = """
            ## Day summary

            ### Overview
            A concise legacy overview.

            ### Work completed and in progress
            \(bullets)

            ### Decisions, follow-ups, and blockers
            None found in the evidence.

            ## Meetings

            _None._

            ## Time allocation

            _No tracked app time._

            ## Chronological work log

            - **17:04–17:30** — **Xcode** — Legacy journal
            """

        let presentation = DayDigestPresentation(markdown: markdown)

        XCTAssertEqual(presentation.atAGlanceMarkdown, "A concise legacy overview.")
        XCTAssertEqual(presentation.focusBlocks.count, 10)
        XCTAssertEqual(presentation.focusBlocks.prefix(3).count, 3)
        XCTAssertNil(presentation.decisionsMarkdown)
        XCTAssertNil(presentation.meetingsMarkdown)
        XCTAssertTrue(presentation.timeAllocations.isEmpty)
        XCTAssertEqual(presentation.activityGroups.first?.label, "17:00–17:59")
    }

    func testOverviewShowsOnlyTheFirstThreeGeneratedHighlights() {
        let markdown = """
            ## Day summary

            ### At a glance
            - First outcome.
            - Second outcome.
            - Third outcome.
            - Fourth lower-priority detail.
            """

        let presentation = DayDigestPresentation(markdown: markdown)

        XCTAssertTrue(presentation.atAGlanceMarkdown.contains("First outcome"))
        XCTAssertTrue(presentation.atAGlanceMarkdown.contains("Third outcome"))
        XCTAssertFalse(presentation.atAGlanceMarkdown.contains("Fourth"))
    }

    func testEmbeddedModesDoNotRepeatHostOwnedSections() {
        XCTAssertFalse(DayDigestView.Mode.timeline.showsTimeAllocation)
        XCTAssertTrue(DayDigestView.Mode.timeline.showsMeetings)
        XCTAssertTrue(DayDigestView.Mode.timeline.showsFullActivityLog)

        XCTAssertFalse(DayDigestView.Mode.today.showsTimeAllocation)
        XCTAssertFalse(DayDigestView.Mode.today.showsMeetings)
        XCTAssertFalse(DayDigestView.Mode.today.showsFullActivityLog)

        XCTAssertTrue(DayDigestView.Mode.standalone.showsTimeAllocation)
        XCTAssertTrue(DayDigestView.Mode.standalone.showsMeetings)
        XCTAssertTrue(DayDigestView.Mode.standalone.showsFullActivityLog)
    }

    func testLegacyUnheadedOverviewAndUnicodeHyphenDecisionSentinel() {
        let markdown = """
            ## Day summary

            The day began with a substantive implementation session.

            ### Work completed and in progress
            - Implemented the structured digest.

            ### Decisions, follow‑ups, and blockers
            None found in the evidence.

            ## Chronological work log
            - **09:00–10:00** — **Xcode** — Implementation
            """

        let presentation = DayDigestPresentation(markdown: markdown)

        XCTAssertEqual(
            presentation.atAGlanceMarkdown,
            "The day began with a substantive implementation session.")
        XCTAssertNil(presentation.decisionsMarkdown)
        XCTAssertEqual(presentation.focusBlocks.count, 1)
    }

    func testOldStandaloneWhatIWorkedOnTableStillParses() {
        let markdown = """
            Date: Wednesday

            ## What I worked on
            - Development and collaboration
            - Analytics and monitoring

            ## Meetings
            None

            ## Time allocation
            | App | Primary use |
            | --- | --- |
            | Google Chrome | Research and monitoring |
            | LokalBot | Local recall |
            """

        let presentation = DayDigestPresentation(markdown: markdown)

        XCTAssertEqual(presentation.focusBlocks.count, 2)
        XCTAssertNil(presentation.meetingsMarkdown)
        XCTAssertEqual(presentation.timeAllocations.map(\.app), ["Google Chrome", "LokalBot"])
        XCTAssertEqual(presentation.timeAllocations.map(\.detail),
                       ["Research and monitoring", "Local recall"])
    }

    func testGenerationPromptEnforcesConciseProgressiveStructure() {
        XCTAssertTrue(PromptTemplates.dayDigestSystem.contains("at_a_glance"))
        XCTAssertTrue(PromptTemplates.dayDigestSystem.contains("35-75 words"))
        XCTAssertTrue(PromptTemplates.dayDigestSystem.contains("Browser toolbars"))
        XCTAssertTrue(PromptTemplates.dayDigestSystem.contains("empty array"))
        XCTAssertTrue(PromptTemplates.dayDigestFocusSystem.contains("exactly one required segment"))
        XCTAssertTrue(PromptTemplates.dayDigestFocusSystem.contains("source_ids"))
        XCTAssertTrue(PromptTemplates.dayDigestFocusSystem.contains("Never begin with \"User\""))
    }
}
