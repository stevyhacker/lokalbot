import XCTest
@testable import LokalBot

final class MeetingSummaryOutcomeSynchronizerTests: XCTestCase {
    func testMeetingSectionsComeOnlyFromGroundedOutcomes() {
        let userCitation = citation(id: "user", start: 1_313)
        let otherCitation = citation(id: "other", start: 1_222)
        let outcomes = MeetingOutcomes(
            actionItems: [
                .init(
                    text: "Me will follow up on WhatsApp",
                    owner: "Me",
                    isForUser: true,
                    citations: [userCitation]),
                .init(
                    text: "Share a sample project",
                    owner: "Ricky",
                    due: "tomorrow",
                    isForUser: false,
                    citations: [otherCitation]),
            ],
            openQuestions: ["What compensation terms remain unresolved?"])
        let modelSummary = """
            # Stevan - Ricky call

            ## TL;DR

            They discussed working together.

            ## Key points

            - The project is local-first.

            ## Decisions

            - They finalized equity-only terms.

            ## Action items

            ### Me
            - [ ] Invented model task

            ### Others
            None

            ## Open questions

            - An unrelated question.

            ## Appendix

            Narrative detail remains.
            """

        let synchronized = MeetingSummaryOutcomeSynchronizer.synchronize(
            modelSummary,
            outcomes: outcomes,
            template: .meeting)

        XCTAssertTrue(synchronized.contains("## TL;DR\n\nThey discussed working together."))
        XCTAssertTrue(synchronized.contains("## Key points\n\n- The project is local-first."))
        XCTAssertTrue(synchronized.contains("## Decisions\n\nNone"), synchronized)
        XCTAssertTrue(synchronized.contains(
            "- [ ] I will follow up on WhatsApp — [00:21:53]"), synchronized)
        XCTAssertTrue(synchronized.contains(
            "- [ ] Ricky: Share a sample project — due tomorrow — [00:20:22]"),
            synchronized)
        XCTAssertTrue(synchronized.contains(
            "## Open questions\n\n- An unrelated question."), synchronized)
        XCTAssertTrue(synchronized.contains("## Appendix\n\nNarrative detail remains."))
        XCTAssertFalse(synchronized.contains("finalized equity-only"), synchronized)
        XCTAssertFalse(synchronized.contains("Invented model task"), synchronized)
    }

    func testMissingMeetingOutcomeSectionsAreAppendedExactlyOnce() {
        let summary = "## TL;DR\n\nA short recap."

        let synchronized = MeetingSummaryOutcomeSynchronizer.synchronize(
            summary,
            outcomes: MeetingOutcomes(),
            template: .meeting)

        XCTAssertEqual(occurrences(of: "## Decisions", in: synchronized), 1)
        XCTAssertEqual(occurrences(of: "## Action items", in: synchronized), 1)
        XCTAssertEqual(occurrences(of: "## Open questions", in: synchronized), 0)
        XCTAssertTrue(synchronized.contains("### Me\nNone\n\n### Others\nNone"), synchronized)
    }

    func testNonMeetingTemplateOnlyControlsActionItems() {
        let summary = """
            ## Concepts

            - Existing concept

            ## Decisions

            - A lecture-specific note

            ## Action items

            - [ ] Unsupported task
            """

        let synchronized = MeetingSummaryOutcomeSynchronizer.synchronize(
            summary,
            outcomes: MeetingOutcomes(),
            template: .lecture)

        XCTAssertTrue(synchronized.contains("- A lecture-specific note"), synchronized)
        XCTAssertFalse(synchronized.contains("Unsupported task"), synchronized)
        XCTAssertFalse(synchronized.contains("## Open questions"), synchronized)
    }

    private func citation(id: String, start: TimeInterval) -> OutcomeSourceCitation {
        OutcomeSourceCitation(
            segmentID: id,
            start: start,
            end: start + 4,
            speaker: "me",
            excerpt: "Evidence")
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
