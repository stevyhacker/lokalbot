import XCTest
@testable import LokalBot

final class TextEngineTests: XCTestCase {
    func testStrippingReasoningRemovesThinkBlocks() {
        let text = """
        <think>hidden chain</think>
        Visible answer.
        """

        XCTAssertEqual(strippingReasoning(text), "Visible answer.")
    }

    func testStrippingReasoningRemovesMultipleThinkBlocks() {
        let text = "<think>a</think>First\n<think>b</think>Second"

        XCTAssertEqual(strippingReasoning(text), "First\nSecond")
    }
}
