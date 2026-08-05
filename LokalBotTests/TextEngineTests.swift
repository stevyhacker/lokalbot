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

    func testBuiltInHighReasoningBudgetReservesHalfOfBoundedOutput() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: TextGenerationOptions(maxTokens: 8_192),
            defaultThinkingBudgetTokens: MainLLMRuntimePolicy.highReasoningBudgetTokens)

        XCTAssertEqual(body["max_tokens"] as? Int, 8_192)
        XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 4_096)
    }

    func testBuiltInHighReasoningUsesFullCeilingWithoutOutputLimit() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: nil,
            defaultThinkingBudgetTokens: MainLLMRuntimePolicy.highReasoningBudgetTokens)

        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 8_192)
    }

    func testExplicitReasoningBudgetCanDisableThinkingForOneRequest() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: TextGenerationOptions(
                maxTokens: 512,
                reasoningBudgetTokens: 0,
                temperature: 0.2),
            defaultThinkingBudgetTokens: MainLLMRuntimePolicy.highReasoningBudgetTokens)

        XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 0)
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
    }

    func testGenericExternalEngineLeavesReasoningAtServerDefault() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: nil,
            defaultThinkingBudgetTokens: nil)

        XCTAssertNil(body["thinking_budget_tokens"])
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
