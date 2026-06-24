import XCTest
@testable import LokalBotV3

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

    /// Pressing Stop cancels the Task mid-request; `send` must surface that as
    /// cancellation, not a `serverUnreachable` error the chat UI renders red.
    func testGenerateMapsTaskCancellationToCancellationError() async {
        let task = Task { () -> String in
            // Blackholed TEST-NET address (RFC 5737): the request can only resolve
            // via cancellation, never a real connection or a fast refusal.
            let engine = OpenAICompatibleEngine(baseURL: URL(string: "http://192.0.2.1:9/")!,
                                                model: "test", apiKey: nil)
            return try await engine.generate(system: "s", prompt: "p", context: [])
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled request should throw")
        } catch is CancellationError {
            // Correct: Stop surfaces as cancellation.
        } catch let error as TextEngineError {
            XCTFail("cancellation misclassified as TextEngineError: \(error)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
