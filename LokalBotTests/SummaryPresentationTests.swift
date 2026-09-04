import XCTest
@testable import LokalBot

final class SummaryPresentationTests: XCTestCase {
    func testSplitsProvenanceLineIntoMetadataAndBody() {
        let markdown = """
            # Standup — August 17, 2026 at 9:00 AM
            **Duration:** 32m · **App:** Zoom · **Words:** 1,204 · **Template:** Meeting notes · **Model:** OpenAI-compatible — x-ai/grok-4.6

            ## Decisions
            Ship the Ask control this week.
            """

        let parts = SummaryPresentation.split(markdown)

        XCTAssertEqual(parts.metadata.map(\.label),
                       ["Duration", "App", "Words", "Template", "Model"])
        XCTAssertEqual(parts.metadata.last?.value, "OpenAI-compatible — x-ai/grok-4.6")
        XCTAssertFalse(parts.body.contains("**Model:**"))
        XCTAssertTrue(parts.body.contains("## Decisions"))
        XCTAssertTrue(parts.body.contains("# Standup"))
    }

    func testLeavesOrdinaryBoldOpenersInTheBody() {
        let markdown = """
            # Notes
            **Next steps:** send the deck.

            The rest of the summary.
            """

        let parts = SummaryPresentation.split(markdown)

        XCTAssertTrue(parts.metadata.isEmpty,
                      "a single bold label is body copy, not provenance")
        XCTAssertTrue(parts.body.contains("**Next steps:**"))
    }

    func testRecapKeepsParagraphImmediatelyBelowHeading() {
        let markdown = "## TL;DR\nA decision and its reason.\n\n## Actions\n- [ ] Follow up."
        XCTAssertEqual(SummaryPresentation.recap(markdown), "A decision and its reason.")
        XCTAssertEqual(SummaryPresentation.split(markdown).body, markdown)
        XCTAssertNil(SummaryPresentation.recap("## Actions\n- [ ] Follow up."))
    }

    func testLeavesSummariesWithoutAProvenanceLineIntact() {
        let markdown = "Just a paragraph with no header metadata."
        let parts = SummaryPresentation.split(markdown)
        XCTAssertTrue(parts.metadata.isEmpty)
        XCTAssertEqual(parts.body, markdown)
    }
}
