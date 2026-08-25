import XCTest
@testable import LokalBot

final class GenerationTestFailurePresentationTests: XCTestCase {
    func testOpenRouterDataPolicyFailureProvidesPrivacyRecovery() throws {
        let error = TextEngineError.httpStatus(
            code: 404,
            detail: "No endpoints found matching your data policy (Paid model training). "
                + "Configure: https://openrouter.ai/settings/privacy",
            retryAfter: nil)

        let presentation = GenerationTestFailurePresentation(
            error: error,
            baseURL: "https://openrouter.ai/api/v1",
            model: "deepseek/deepseek-v4-flash-vision-exp")

        XCTAssertEqual(presentation.kind, .openRouterDataPolicy)
        XCTAssertEqual(presentation.title, "OpenRouter privacy settings block this model")
        XCTAssertTrue(presentation.explanation.contains("deepseek-v4-flash-vision-exp"))
        XCTAssertTrue(presentation.recovery.contains("Paid model training"))
        XCTAssertTrue(presentation.privacyNote?.contains("training disabled") == true)
        XCTAssertEqual(
            presentation.actionURL,
            URL(string: "https://openrouter.ai/settings/privacy"))
        XCTAssertTrue(presentation.technicalDetails.contains("HTTP 404"))
    }

    func testDataPolicyTextFromAnotherServerDoesNotCreateOpenRouterLink() {
        let error = TextEngineError.httpStatus(
            code: 404,
            detail: "No endpoints found matching your data policy (Paid model training).",
            retryAfter: nil)

        let presentation = GenerationTestFailurePresentation(
            error: error,
            baseURL: "https://inference.example.com/v1",
            model: "example/model")

        XCTAssertEqual(presentation.kind, .generic)
        XCTAssertNil(presentation.actionTitle)
        XCTAssertNil(presentation.actionURL)
    }

    func testUnrelatedOpenRouterFailureKeepsGenericGuidanceAndFullError() {
        let error = TextEngineError.httpStatus(
            code: 401,
            detail: "Invalid API key",
            retryAfter: nil)

        let presentation = GenerationTestFailurePresentation(
            error: error,
            baseURL: "https://openrouter.ai/api/v1",
            model: "deepseek/deepseek-v4-flash-vision-exp")

        XCTAssertEqual(presentation.kind, .generic)
        XCTAssertEqual(presentation.title, "Generation test failed")
        XCTAssertNil(presentation.actionURL)
        XCTAssertEqual(
            presentation.technicalDetails,
            "LLM server returned HTTP 401: Invalid API key")
    }
}
