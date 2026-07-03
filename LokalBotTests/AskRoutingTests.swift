import XCTest
@testable import LokalBot

/// The Ask surface's phase routing (spec §2.3 "one input, two response
/// modes"): a non-empty query always shows live results; an empty query
/// falls back to the conversation when one exists, else the empty state.
final class AskRoutingTests: XCTestCase {

    func testNonEmptyQueryAlwaysSearches() {
        XCTAssertEqual(AskRouter.phase(query: "failover", hasMessages: false), .searching)
        XCTAssertEqual(AskRouter.phase(query: "failover", hasMessages: true), .searching)
    }

    func testEmptyQueryShowsConversationWhenMessagesExist() {
        XCTAssertEqual(AskRouter.phase(query: "", hasMessages: true), .conversation)
    }

    func testEmptyQueryShowsIdleWithoutMessages() {
        XCTAssertEqual(AskRouter.phase(query: "", hasMessages: false), .idle)
    }

    func testWhitespaceOnlyQueryCountsAsEmpty() {
        XCTAssertEqual(AskRouter.phase(query: "  \n ", hasMessages: true), .conversation)
        XCTAssertEqual(AskRouter.phase(query: "  ", hasMessages: false), .idle)
    }

    func testFacetKindMapping() {
        XCTAssertNil(AskFacet.all.kind)
        XCTAssertNil(AskFacet.screen.kind)
        XCTAssertEqual(AskFacet.transcripts.kind, .segment)
        XCTAssertEqual(AskFacet.summaries.kind, .summary)
    }
}
