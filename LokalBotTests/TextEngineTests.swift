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
            defaultThinkingBudgetTokens: MainLLMRuntimePolicy.highReasoningBudgetTokens,
            dialect: .llamaServer,
            model: "local")

        XCTAssertEqual(body["max_tokens"] as? Int, 8_192)
        XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 4_096)
    }

    func testBuiltInHighReasoningUsesFullCeilingWithoutOutputLimit() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: nil,
            defaultThinkingBudgetTokens: MainLLMRuntimePolicy.highReasoningBudgetTokens,
            dialect: .llamaServer,
            model: "local")

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
            defaultThinkingBudgetTokens: MainLLMRuntimePolicy.highReasoningBudgetTokens,
            dialect: .llamaServer,
            model: "local")

        XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 0)
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
    }

    func testGenericExternalEngineLeavesReasoningAtServerDefault() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: TextGenerationOptions(maxTokens: 700,
                                           reasoningBudgetTokens: 256,
                                           temperature: 0.2),
            defaultThinkingBudgetTokens: nil,
            dialect: .generic,
            model: "generic")

        XCTAssertNil(body["thinking_budget_tokens"])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertEqual(body["max_tokens"] as? Int, 700)
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
    }

    func testOfficialOpenAIUsesModernReasoningFieldsWithoutSamplingExtension() throws {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://api.openai.com/v1")!,
            model: "gpt-5.4-mini",
            apiKey: "test-token",
            chatDialect: .openAI)

        let request = try engine.makeChatRequest(
            system: "system",
            prompt: "prompt",
            context: [],
            schema: nil,
            options: TextGenerationOptions(maxTokens: 700,
                                           reasoningBudgetTokens: 256,
                                           temperature: 0.2))
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(body["max_completion_tokens"] as? Int, 700)
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        XCTAssertNil(body["max_tokens"])
        XCTAssertNil(body["thinking_budget_tokens"])
        XCTAssertNil(body["temperature"])
    }

    func testOfficialNonReasoningModelKeepsTemperature() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: TextGenerationOptions(maxTokens: 300,
                                           reasoningBudgetTokens: 256,
                                           temperature: 0.4),
            defaultThinkingBudgetTokens: nil,
            dialect: .openAI,
            model: "gpt-4.1-mini")

        XCTAssertEqual(body["max_completion_tokens"] as? Int, 300)
        XCTAssertEqual(body["temperature"] as? Double, 0.4)
        XCTAssertNil(body["reasoning_effort"])
    }

    func testDialectInferenceSelectsKnownRemoteProviders() {
        XCTAssertEqual(
            ChatCompletionDialect.inferred(
                from: URL(string: "https://api.openai.com/v1")!),
            .openAI)
        XCTAssertEqual(
            ChatCompletionDialect.inferred(
                from: URL(string: "https://openrouter.ai/api/v1")!),
            .openRouter)
        XCTAssertEqual(
            ChatCompletionDialect.inferred(
                from: URL(string: "https://eu.openrouter.ai/api/v1")!),
            .openRouter)
        XCTAssertEqual(
            ChatCompletionDialect.inferred(
                from: URL(string: "http://localhost:1234/v1")!),
            .generic)
    }

    func testOpenRouterUsesNativeReasoningAndPrivacyRouting() throws {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "anthropic/example-model",
            apiKey: "test-token",
            chatDialect: .openRouter)
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["answer": ["type": "string"]],
            "required": ["answer"],
            "additionalProperties": false,
        ]

        let request = try engine.makeChatRequest(
            system: "system",
            prompt: "prompt",
            context: [],
            schema: schema,
            options: TextGenerationOptions(maxTokens: 700,
                                           reasoningBudgetTokens: 256,
                                           temperature: 0.2))
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])

        XCTAssertEqual(request.url?.absoluteString,
                       "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer test-token")
        XCTAssertEqual(body["max_tokens"] as? Int, 700)
        XCTAssertEqual(reasoning["max_tokens"] as? Int, 256)
        XCTAssertEqual(reasoning["exclude"] as? Bool, true)
        XCTAssertEqual(provider["data_collection"] as? String, "deny")
        XCTAssertEqual(provider["require_parameters"] as? Bool, true)
        XCTAssertNil(body["max_completion_tokens"])
        XCTAssertNil(body["thinking_budget_tokens"])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertNil(body["temperature"])
    }

    func testOpenRouterPlainChatKeepsTemperatureWithoutForcingParameters() throws {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "openai/example-model",
            apiKey: "test-token",
            chatDialect: .openRouter)

        let request = try engine.makeChatRequest(
            system: "system",
            prompt: "prompt",
            context: [],
            schema: nil,
            options: TextGenerationOptions(maxTokens: 300, temperature: 0.4))
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])

        XCTAssertEqual(body["max_tokens"] as? Int, 300)
        XCTAssertEqual(body["temperature"] as? Double, 0.4)
        XCTAssertEqual(provider["data_collection"] as? String, "deny")
        XCTAssertNil(provider["require_parameters"])
        XCTAssertNil(body["reasoning"])
    }

    func testOpenRouterCanFollowAccountDataPolicy() throws {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "deepseek/example-model",
            apiKey: "test-token",
            chatDialect: .openRouter,
            openRouterDataPolicy: .accountPolicy)

        let request = try engine.makeChatRequest(
            system: "system",
            prompt: "prompt",
            context: [],
            schema: nil,
            options: nil)
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])

        XCTAssertEqual(provider["data_collection"] as? String, "allow")
    }

    func testOpenRouterHighReasoningFallbackUsesEffortHigh() throws {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "z-ai/glm-5.3",
            apiKey: "test-token",
            chatDialect: .openRouter)
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["answer": ["type": "string"]],
            "required": ["answer"],
            "additionalProperties": false,
        ]

        let request = try engine.makeChatRequest(
            system: "system",
            prompt: "prompt",
            context: [],
            schema: schema,
            options: TextGenerationOptions(
                maxTokens: 768,
                reasoningBudgetTokens: 256,
                temperature: 0.2),
            openRouterReasoning: .highEffort)
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])

        XCTAssertEqual(reasoning["effort"] as? String, "high")
        XCTAssertNil(reasoning["max_tokens"])
        XCTAssertNil(reasoning["exclude"])
        XCTAssertEqual(body["max_tokens"] as? Int, 768)
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["response_format"],
                     "strict json_schema is what 404s GLM-5.3 after the reasoning remap")
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])
        XCTAssertEqual(provider["data_collection"] as? String, "deny")
        XCTAssertNil(provider["require_parameters"])
    }

    func testOpenRouterHighReasoningFallbackReplacesDisabledReasoning() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: TextGenerationOptions(
                maxTokens: 1_600,
                reasoningBudgetTokens: 0,
                temperature: 0),
            defaultThinkingBudgetTokens: nil,
            dialect: .openRouter,
            model: "z-ai/glm-5.3",
            openRouterReasoning: .highEffort)

        let reasoning = body["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["effort"] as? String, "high")
        XCTAssertNil(reasoning?["max_tokens"])
        XCTAssertNil(body["temperature"])
    }

    func testOpenRouterSchemaOnlyFallbackDropsStructuredRequirements() throws {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "stealth/ox-alpha",
            apiKey: "test-token",
            chatDialect: .openRouter)
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["answer": ["type": "string"]],
            "required": ["answer"],
            "additionalProperties": false,
        ]

        let request = try engine.makeChatRequest(
            system: "system",
            prompt: "prompt",
            context: [],
            schema: schema,
            options: nil,
            openRouterReasoning: .highEffort)
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])

        XCTAssertEqual(reasoning["effort"] as? String, "high")
        XCTAssertNil(body["response_format"])
        XCTAssertEqual(provider["data_collection"] as? String, "deny")
        XCTAssertNil(provider["require_parameters"])
    }

    func testOpenRouterParameterMismatchTriggersHighReasoningFallbackOnce() {
        let mismatch = TextEngineError.httpStatus(
            code: 404,
            detail: "No endpoints found that can handle the requested parameters. "
                + "To learn more about provider routing, visit: "
                + "https://openrouter.ai/docs/guides/routing/provider-selection",
            retryAfter: nil)
        let missingModel = TextEngineError.httpStatus(
            code: 404, detail: "No endpoints found for model z-ai/glm-5.3", retryAfter: nil)

        XCTAssertTrue(OpenAICompatibleEngine.shouldFallbackToHighReasoning(
            dialect: .openRouter, error: mismatch, usedFallback: false,
            requestedSchema: false,
            requestedReasoningBudget: 256))
        XCTAssertTrue(OpenAICompatibleEngine.shouldFallbackToHighReasoning(
            dialect: .openRouter, error: mismatch, usedFallback: false,
            requestedSchema: false,
            requestedReasoningBudget: 0),
                       "effort:none retries also need the high-reasoning fallback")
        XCTAssertTrue(OpenAICompatibleEngine.shouldFallbackToHighReasoning(
            dialect: .openRouter, error: mismatch, usedFallback: false,
            requestedSchema: true,
            requestedReasoningBudget: nil),
                       "schema-only callers such as Dreaming need the compatibility fallback")
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToHighReasoning(
            dialect: .openRouter, error: mismatch, usedFallback: true,
            requestedSchema: true,
            requestedReasoningBudget: 256))
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToHighReasoning(
            dialect: .openRouter, error: missingModel, usedFallback: false,
            requestedSchema: true,
            requestedReasoningBudget: 256))
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToHighReasoning(
            dialect: .generic, error: mismatch, usedFallback: false,
            requestedSchema: true,
            requestedReasoningBudget: 256))
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToHighReasoning(
            dialect: .openRouter, error: mismatch, usedFallback: false,
            requestedSchema: false,
            requestedReasoningBudget: nil))
    }

    func testOpenRouterMandatoryReasoningErrorTriggersHighReasoningFallbackOnce() {
        let mandatory = TextEngineError.httpStatus(
            code: 400,
            detail: "Reasoning is mandatory for this endpoint and cannot be disabled.",
            retryAfter: nil)
        let unrelated = TextEngineError.httpStatus(
            code: 400, detail: "Invalid JSON schema", retryAfter: nil)

        XCTAssertTrue(OpenAICompatibleEngine.shouldFallbackToHighReasoning(
            dialect: .openRouter, error: mandatory, usedFallback: false,
            requestedSchema: true,
            requestedReasoningBudget: 0))
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToHighReasoning(
            dialect: .openRouter, error: mandatory, usedFallback: true,
            requestedSchema: true,
            requestedReasoningBudget: 0))
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToHighReasoning(
            dialect: .openRouter, error: mandatory, usedFallback: false,
            requestedSchema: true,
            requestedReasoningBudget: 256))
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToHighReasoning(
            dialect: .generic, error: mandatory, usedFallback: false,
            requestedSchema: true,
            requestedReasoningBudget: 0))
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToHighReasoning(
            dialect: .openRouter, error: unrelated, usedFallback: false,
            requestedSchema: true,
            requestedReasoningBudget: 0))
    }

    func testOpenRouterCanDisableReasoningForStructuredRetry() throws {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "deepseek/example-model",
            apiKey: "test-token",
            chatDialect: .openRouter)
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["answer": ["type": "string"]],
            "required": ["answer"],
            "additionalProperties": false,
        ]

        let request = try engine.makeChatRequest(
            system: "system",
            prompt: "prompt",
            context: [],
            schema: schema,
            options: TextGenerationOptions(
                maxTokens: 1_600,
                reasoningBudgetTokens: 0,
                temperature: 0))
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])

        XCTAssertEqual(reasoning["effort"] as? String, "none")
        XCTAssertEqual(body["temperature"] as? Double, 0)
        XCTAssertEqual(provider["require_parameters"] as? Bool, true)
    }

    func testOpenRouterRejectsInvalidStrictSchemaLocally() {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "openai/example-model",
            apiKey: "test-token",
            chatDialect: .openRouter)
        let invalidSchema: [String: Any] = [
            "type": "object",
            "properties": ["answer": ["type": "string"]],
            "required": ["answer"],
        ]

        XCTAssertThrowsError(try engine.makeChatRequest(
            system: "system",
            prompt: "prompt",
            context: [],
            schema: invalidSchema,
            options: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("invalid strict JSON schema"))
        }
    }

    func testParseChatCompletionCapturesUsage() throws {
        let data = try XCTUnwrap(#"""
            {
              "choices": [{"finish_reason": "stop", "message": {"content": "Done"}}],
              "usage": {
                "prompt_tokens": 30,
                "completion_tokens": 12,
                "prompt_tokens_details": {"cached_tokens": 20},
                "completion_tokens_details": {"reasoning_tokens": 4}
              }
            }
            """#.data(using: .utf8))

        let parsed = try OpenAICompatibleEngine.parseChatCompletion(data)

        XCTAssertEqual(parsed.content, "Done")
        XCTAssertEqual(parsed.usage,
                       .init(inputTokens: 30, outputTokens: 12,
                             cachedInputTokens: 20, reasoningOutputTokens: 4))
    }

    func testParseChatCompletionRejectsTruncationAndRefusal() throws {
        let truncated = try XCTUnwrap(#"""
            {"choices": [{"finish_reason": "length", "message": {"content": "partial"}}]}
            """#.data(using: .utf8))
        XCTAssertThrowsError(try OpenAICompatibleEngine.parseChatCompletion(truncated)) {
            guard case TextEngineError.outputTruncated = $0 else {
                return XCTFail("Expected outputTruncated, got \($0)")
            }
            XCTAssertTrue($0.localizedDescription.contains("truncated"))
        }

        let refusal = try XCTUnwrap(#"""
            {"choices": [{"finish_reason": "stop", "message": {"content": null, "refusal": "Cannot comply"}}]}
            """#.data(using: .utf8))
        XCTAssertThrowsError(try OpenAICompatibleEngine.parseChatCompletion(refusal)) {
            XCTAssertTrue($0.localizedDescription.contains("refusal"))
        }
    }

    func testRetryPolicyHonorsRetryAfterAndRejectsPermanentErrors() {
        let rateLimit = TextEngineError.httpStatus(
            code: 429, detail: "slow down", retryAfter: 3)
        XCTAssertEqual(TextEngineRetryPolicy.delay(
            for: rateLimit, attempt: 0, jitter: 0), 3)

        let serverFailure = TextEngineError.httpStatus(
            code: 503, detail: "warming", retryAfter: nil)
        XCTAssertEqual(TextEngineRetryPolicy.delay(
            for: serverFailure, attempt: 0, jitter: 0.25), 1.25)

        let invalidRequest = TextEngineError.httpStatus(
            code: 400, detail: "bad schema", retryAfter: nil)
        XCTAssertNil(TextEngineRetryPolicy.delay(
            for: invalidRequest, attempt: 0, jitter: 0))
        XCTAssertNil(TextEngineRetryPolicy.delay(
            for: rateLimit, attempt: 1, jitter: 0))
    }

    func testHTTPErrorParsesSafeDetailRequestIDAndRetryAfter() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "2", "x-request-id": "req_test"]))
        let data = try XCTUnwrap(
            #"{"error":{"message":"Rate limit reached"}}"#.data(using: .utf8))

        guard case .httpStatus(let code, let detail, let retryAfter) =
                TextEngineError.fromHTTPResponse(response, data: data) else {
            return XCTFail("expected HTTP status error")
        }
        XCTAssertEqual(code, 429)
        XCTAssertTrue(detail.contains("Rate limit reached"))
        XCTAssertTrue(detail.contains("req_test"))
        XCTAssertEqual(retryAfter, 2)
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
