import Foundation

/// The Main LLM engine's text generation: summaries, day digests, Q&A
/// (design doc §5). Both backends speak HTTP to localhost only — the model
/// itself runs in Ollama, LM Studio, or any OpenAI-compatible server the
/// user points us at.
protocol TextEngine {
    var displayName: String { get }
    func generate(system: String, prompt: String, context: [String]) async throws -> String
    func generate(system: String, prompt: String, context: [String],
                  options: TextGenerationOptions) async throws -> String

    /// JSON-schema-constrained generation. Backends with decode-time
    /// constraints guarantee the reply parses against `schema` (llama-server
    /// compiles it to a GBNF grammar; Ollama takes it as `format`). The
    /// default ignores the schema, so callers must keep their tolerant-parse
    /// fallback for backends that can't constrain (Apple Intelligence).
    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any]) async throws -> String
    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any],
                  options: TextGenerationOptions) async throws -> String

    /// Low-latency raw text continuation for cotyping (inline autocomplete).
    /// The default delegates to `generate` with an autocomplete instruction so
    /// every backend works; `OpenAICompatibleEngine` overrides it to hit raw
    /// `/v1/completions`, which is faster and behaves as a pure text continuer.
    func complete(_ request: CompletionRequest) async throws -> String

    /// Streaming variant of `complete`: `onPartial` receives the cumulative
    /// completion text as tokens arrive, so the UI can paint ghost text before
    /// the full response finishes. Returns the final text. Default is
    /// non-streaming; `OpenAICompatibleEngine` overrides it with SSE.
    func completeStreaming(_ request: CompletionRequest,
                           onPartial: @escaping @Sendable (String) -> Void) async throws -> String
}

/// Per-request generation controls shared by the local chat backends. A nil
/// reasoning budget inherits the engine's default.
struct TextGenerationOptions: Equatable, Sendable {
    var maxTokens: Int?
    var reasoningBudgetTokens: Int?
    var temperature: Double?

    init(maxTokens: Int? = nil, reasoningBudgetTokens: Int? = nil,
         temperature: Double? = nil) {
        self.maxTokens = maxTokens
        self.reasoningBudgetTokens = reasoningBudgetTokens
        self.temperature = temperature
    }
}

/// Request fields differ between bundled llama-server, generic compatible
/// servers, OpenAI, and OpenRouter. Keep the dialect explicit so one
/// provider's extensions can never leak into another provider's request.
enum ChatCompletionDialect: Equatable, Sendable {
    case llamaServer
    case openAI
    case openRouter
    case generic

    static func inferred(from baseURL: URL) -> Self {
        let host = baseURL.host?.lowercased()
        if host == "api.openai.com" { return .openAI }
        if host == "openrouter.ai" || host?.hasSuffix(".openrouter.ai") == true {
            return .openRouter
        }
        return .generic
    }
}

/// OpenRouter request shape. Native uses `max_tokens`/`exclude` or
/// `effort: none` plus strict `json_schema`. High-effort is the fallback
/// for models that cannot disable thinking or honor structured outputs
/// (for example GLM-5.3): `effort: high`, no schema, no require_parameters.
enum OpenRouterReasoningCompatibility: Equatable, Sendable {
    case native
    case highEffort
}

enum TextEngineError: LocalizedError, Sendable {
    case serverUnreachable(String, transportCode: Int?)
    case badResponse(String)
    case outputTruncated
    case httpStatus(code: Int, detail: String, retryAfter: TimeInterval?)
    case noModel
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .serverUnreachable(let base, _):
            "Can't reach \(base). Verify that the configured LLM server is available."
        case .badResponse(let detail):
            "LLM server error: \(detail)"
        case .outputTruncated:
            "LLM server error: response was truncated at the model output limit"
        case .httpStatus(let code, let detail, _):
            "LLM server returned HTTP \(code): \(detail)"
        case .noModel:
            "No model selected for the Main LLM engine. Pick one in Settings → Models."
        case .unavailable(let detail):
            detail
        }
    }

    var isRetryable: Bool {
        switch self {
        case .serverUnreachable:
            true
        case .httpStatus(let code, _, _):
            code == 408 || code == 409 || code == 425 || code == 429 || (500...599).contains(code)
        case .badResponse, .outputTruncated, .noModel, .unavailable:
            false
        }
    }

    var retryAfter: TimeInterval? {
        guard case .httpStatus(_, _, let retryAfter) = self else { return nil }
        return retryAfter
    }

    static func fromHTTPResponse(_ response: HTTPURLResponse?, data: Data) -> TextEngineError {
        guard let response else { return .badResponse("missing HTTP response") }
        let detail = serverErrorDetail(data)
        let requestID = response.value(forHTTPHeaderField: "x-request-id")
        let diagnostic = requestID.map { "\(detail) (request ID: \($0))" } ?? detail
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap { TimeInterval($0) }
            .map { max(0, $0) }
        return .httpStatus(code: response.statusCode,
                           detail: diagnostic,
                           retryAfter: retryAfter)
    }

    private static func serverErrorDetail(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return clipped(message)
        }
        guard let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return "empty error response"
        }
        return clipped(text)
    }

    private static func clipped(_ text: String) -> String {
        String(text.prefix(600))
    }
}

/// One bounded retry for transient transport/status failures. Permanent 4xx,
/// invalid payloads, cancellations, and missing configuration are never retried.
enum TextEngineRetryPolicy {
    static let maximumDelay: TimeInterval = 60

    static func delay(for error: Error, attempt: Int,
                      jitter: TimeInterval = Double.random(in: 0...0.5)) -> TimeInterval? {
        guard attempt == 0,
              let engineError = error as? TextEngineError,
              engineError.isRetryable else { return nil }
        if let retryAfter = engineError.retryAfter {
            return min(retryAfter, maximumDelay)
        }
        return min(pow(2, Double(attempt)) + max(0, jitter), maximumDelay)
    }
}

/// OpenAI strict Structured Outputs accepts a JSON Schema subset. Validate the
/// invariants LokalBot relies on locally so malformed schemas never consume a
/// remote request merely to receive a deterministic 400 response.
enum OpenAIStrictSchemaValidator {
    static func validationIssue(in schema: [String: Any]) -> String? {
        guard schema["type"] as? String == "object" else {
            return "$ must be an object schema"
        }
        return validationIssue(in: schema, path: "$")
    }

    private static func validationIssue(in node: [String: Any], path: String) -> String? {
        if let variants = node["anyOf"] as? [[String: Any]] {
            for (index, variant) in variants.enumerated() {
                if let issue = validationIssue(in: variant, path: "\(path).anyOf[\(index)]") {
                    return issue
                }
            }
        }

        let isObject = node["type"] as? String == "object"
            || (node["type"] as? [String])?.contains("object") == true
        if isObject {
            guard node["additionalProperties"] as? Bool == false else {
                return "\(path) must set additionalProperties to false"
            }
            guard let properties = node["properties"] as? [String: Any] else {
                return "\(path) must declare properties"
            }
            let required = Set(node["required"] as? [String] ?? [])
            let propertyNames = Set(properties.keys)
            guard required == propertyNames else {
                let missing = propertyNames.subtracting(required).sorted().joined(separator: ", ")
                return "\(path) must require every property; missing: \(missing)"
            }
            for name in properties.keys.sorted() {
                guard let property = properties[name] as? [String: Any] else {
                    return "\(path).properties.\(name) is not a schema object"
                }
                if let issue = validationIssue(in: property,
                                               path: "\(path).properties.\(name)") {
                    return issue
                }
            }
        }

        let isArray = node["type"] as? String == "array"
            || (node["type"] as? [String])?.contains("array") == true
        if isArray {
            guard let items = node["items"] as? [String: Any] else {
                return "\(path) must declare array items"
            }
            if let issue = validationIssue(in: items, path: "\(path).items") { return issue }
        }

        if let definitions = node["$defs"] as? [String: Any] {
            for name in definitions.keys.sorted() {
                guard let definition = definitions[name] as? [String: Any] else {
                    return "\(path).$defs.\(name) is not a schema object"
                }
                if let issue = validationIssue(in: definition,
                                               path: "\(path).$defs.\(name)") {
                    return issue
                }
            }
        }
        return nil
    }
}

/// Generation can legitimately take minutes for a long meeting on a laptop.
private let llmSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 600
    config.timeoutIntervalForResource = 900
    return URLSession(configuration: config)
}()

/// Strips `<think>…</think>` reasoning blocks that models like Qwen 3 and
/// DeepSeek R1 emit before the actual answer.
func strippingReasoning(_ text: String) -> String {
    var result = text
    while let open = result.range(of: "<think>"),
          let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
        result.removeSubrange(open.lowerBound..<close.upperBound)
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Cotyping completion

/// One short continuation request for cotyping. Separate from `generate`'s
/// chat shape because inline autocomplete wants a raw prompt, tight sampling,
/// stop sequences, and a low latency budget.
struct CompletionRequest: Sendable {
    var prompt: String
    var maxTokens: Int
    var temperature: Double
    var topP: Double
    var topK: Int
    var minP: Double
    var repeatPenalty: Double
    var seed: Int
    var stop: [String]
}

/// Cotyping must feel instant, so completions use a short timeout rather than
/// `generate`'s minutes-long budget. Swift `Task` cancellation (the coordinator
/// supersedes stale keystrokes) surfaces here as `URLError.cancelled`.
private let completionSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 12
    config.timeoutIntervalForResource = 15
    return URLSession(configuration: config)
}()

func cotypingCompletionSend(_ request: URLRequest, base: URL) async throws -> (Data, URLResponse) {
    do {
        return try await completionSession.data(for: request)
    } catch let error as URLError where error.code == .cancelled {
        throw error
    } catch {
        let diagnostic = error as NSError
        lokalbotLog(
            "text engine transport failure host=\(base.host ?? "unknown") "
                + "domain=\(diagnostic.domain) code=\(diagnostic.code)")
        throw TextEngineError.serverUnreachable(
            base.absoluteString,
            transportCode: diagnostic.code)
    }
}

struct CotypingSSEEvent: Equatable {
    var delta: String?
    var isTerminal: Bool
}

/// Parses one Server-Sent-Events line from an OpenAI-style streaming
/// completion. A terminal event is either `[DONE]` or a choice carrying a
/// non-null `finish_reason`.
func cotypingParseSSEEvent(_ line: String) -> CotypingSSEEvent? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("data:") else { return nil }
    let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
    guard !payload.isEmpty else { return nil }
    if payload == "[DONE]" { return CotypingSSEEvent(delta: nil, isTerminal: true) }
    guard let data = payload.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choice = (json["choices"] as? [[String: Any]])?.first else { return nil }
    let finishReason = choice["finish_reason"] as? String
    return CotypingSSEEvent(delta: choice["text"] as? String,
                            isTerminal: finishReason != nil)
}

/// Compatibility helper used by the lightweight parser tests and callers that
/// only care about text-bearing chunks.
func cotypingParseSSEDelta(_ line: String) -> String? {
    cotypingParseSSEEvent(line)?.delta
}

extension TextEngine {
    /// Backends without an output-budget control keep their existing behavior.
    func generate(system: String, prompt: String, context: [String],
                  options: TextGenerationOptions) async throws -> String {
        try await generate(system: system, prompt: prompt, context: context)
    }

    /// Unconstrained fallback for backends without decode-time grammar support.
    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any]) async throws -> String {
        try await generate(system: system, prompt: prompt, context: context)
    }

    /// Backends that cannot combine grammar constraints with request controls
    /// still preserve the schema. Built-in llama-server and Ollama override
    /// this path so digest extraction also gets its explicit sampling policy.
    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any],
                  options: TextGenerationOptions) async throws -> String {
        try await generate(system: system, prompt: prompt, context: context,
                           schema: schema)
    }

    /// Chat-backend fallback: ask the model to continue the text and emit only
    /// the continuation. Used by Ollama / Apple Intelligence; the built-in
    /// llama-server (OpenAI-compatible) overrides this with the raw endpoint.
    func complete(_ request: CompletionRequest) async throws -> String {
        try await generate(system: PromptTemplates.autocompleteSystem,
                           prompt: request.prompt, context: [])
    }

    /// Non-streaming fallback: run once, emit the whole result as one partial.
    func completeStreaming(_ request: CompletionRequest,
                           onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        let result = try await complete(request)
        onPartial(result)
        return result
    }
}

// MARK: - Ollama

struct OllamaEngine: TextEngine {
    var baseURL: URL
    var model: String

    var displayName: String { "Ollama — \(model)" }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        try await chat(system: system, prompt: prompt, context: context, schema: nil, options: nil)
    }

    func generate(system: String, prompt: String, context: [String],
                  options: TextGenerationOptions) async throws -> String {
        try await chat(system: system, prompt: prompt, context: context,
                       schema: nil, options: options)
    }

    /// Ollama enforces JSON schemas natively via the `format` field.
    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any]) async throws -> String {
        try await chat(system: system, prompt: prompt, context: context,
                       schema: schema, options: nil)
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any],
                  options: TextGenerationOptions) async throws -> String {
        try await chat(system: system, prompt: prompt, context: context,
                       schema: schema, options: options)
    }

    private func chat(system: String, prompt: String, context: [String],
                      schema: [String: Any]?,
                      options: TextGenerationOptions?) async throws -> String {
        guard !model.isEmpty else { throw TextEngineError.noModel }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let user = (context + [prompt]).joined(separator: "\n\n")
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if let schema { body["format"] = schema }
        var generationOptions: [String: Any] = [:]
        if let maxTokens = options?.maxTokens {
            generationOptions["num_predict"] = max(1, maxTokens)
        }
        if let temperature = options?.temperature {
            generationOptions["temperature"] = max(0, temperature)
        }
        if !generationOptions.isEmpty { body["options"] = generationOptions }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request, base: baseURL)
        let httpResponse = response as? HTTPURLResponse
        guard let status = httpResponse?.statusCode, (200...299).contains(status) else {
            throw TextEngineError.fromHTTPResponse(httpResponse, data: data)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TextEngineError.badResponse("unexpected /api/chat payload")
        }
        return strippingReasoning(content)
    }

    /// Model names from `GET /api/tags`; empty array if the server is down.
    static func listModels(baseURL: URL) async -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        guard let (data, _) = try? await llmSession.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
    }
}

// MARK: - OpenAI-compatible localhost (LM Studio, vllm-mlx, …)

struct OpenAICompatibleEngine: TextEngine {
    var baseURL: URL        // e.g. http://localhost:1234/v1
    var model: String
    var apiKey: String?
    /// Extra top-level request fields for server-specific compatibility.
    var extraBody: [String: Any] = [:]
    var chatDialect: ChatCompletionDialect = .generic
    /// llama-server's request-level thinking ceiling. Kept nil for generic
    /// external endpoints that may not understand this extension.
    var defaultThinkingBudgetTokens: Int?
    var displayNameOverride: String?

    var displayName: String { displayNameOverride ?? "OpenAI-compatible — \(model)" }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        try await chat(system: system, prompt: prompt, context: context, schema: nil, options: nil)
    }

    func generate(system: String, prompt: String, context: [String],
                  options: TextGenerationOptions) async throws -> String {
        try await chat(system: system, prompt: prompt, context: context,
                       schema: nil, options: options)
    }

    /// OpenAI-standard structured output: llama-server compiles the schema to
    /// a GBNF grammar and constrains decoding; LM Studio / vllm honour the
    /// same `response_format` shape.
    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any]) async throws -> String {
        try await chat(system: system, prompt: prompt, context: context,
                       schema: schema, options: nil)
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any],
                  options: TextGenerationOptions) async throws -> String {
        try await chat(system: system, prompt: prompt, context: context,
                       schema: schema, options: options)
    }

    private func chat(system: String, prompt: String, context: [String],
                      schema: [String: Any]?,
                      options: TextGenerationOptions?) async throws -> String {
        try await chat(
            system: system, prompt: prompt, context: context,
            schema: schema, options: options, openRouterReasoning: .native)
    }

    private func chat(system: String, prompt: String, context: [String],
                      schema: [String: Any]?,
                      options: TextGenerationOptions?,
                      openRouterReasoning: OpenRouterReasoningCompatibility) async throws -> String {
        guard !model.isEmpty else { throw TextEngineError.noModel }
        let request = try makeChatRequest(system: system, prompt: prompt, context: context,
                                          schema: schema, options: options,
                                          openRouterReasoning: openRouterReasoning)
        do {
            return try await completeChat(request)
        } catch {
            guard Self.shouldFallbackToHighReasoning(
                dialect: chatDialect,
                error: error,
                usedFallback: openRouterReasoning == .highEffort,
                requestedReasoningBudget: options?.reasoningBudgetTokens)
            else { throw error }
            lokalbotLog("openrouter reasoning fallback effort=high model=\(model)")
            return try await chat(
                system: system, prompt: prompt, context: context,
                schema: schema, options: options, openRouterReasoning: .highEffort)
        }
    }

    private func completeChat(_ request: URLRequest) async throws -> String {
        let (data, response) = try await send(request, base: baseURL)
        let httpResponse = response as? HTTPURLResponse
        guard let status = httpResponse?.statusCode, (200...299).contains(status) else {
            throw TextEngineError.fromHTTPResponse(httpResponse, data: data)
        }
        let parsed = try Self.parseChatCompletion(data)
        if let usage = parsed.usage {
            lokalbotLog(
                "generation usage model=\(model) input=\(usage.inputTokens) "
                    + "output=\(usage.outputTokens) cached=\(usage.cachedInputTokens) "
                    + "reasoning=\(usage.reasoningOutputTokens)")
        }
        return strippingReasoning(parsed.content)
    }

    /// Pure request construction keeps provider-field compatibility covered by
    /// offline tests without requiring credentials or a billable call.
    func makeChatRequest(system: String, prompt: String, context: [String],
                         schema: [String: Any]?,
                         options: TextGenerationOptions?,
                         openRouterReasoning: OpenRouterReasoningCompatibility = .native) throws -> URLRequest {
        if chatDialect == .openAI
            || (chatDialect == .openRouter && openRouterReasoning != .highEffort),
           let schema,
           let issue = OpenAIStrictSchemaValidator.validationIssue(in: schema) {
            throw TextEngineError.badResponse("invalid strict JSON schema: \(issue)")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let user = (context + [prompt]).joined(separator: "\n\n")
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if let schema, !(chatDialect == .openRouter && openRouterReasoning == .highEffort) {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "response", "strict": true, "schema": schema],
            ]
        }
        Self.applyGenerationOptions(
            to: &body,
            options: options,
            defaultThinkingBudgetTokens: defaultThinkingBudgetTokens,
            dialect: chatDialect,
            model: model,
            openRouterReasoning: openRouterReasoning)
        if chatDialect == .openRouter {
            var provider: [String: Any] = ["data_collection": "deny"]
            if openRouterReasoning != .highEffort,
               schema != nil || (options?.reasoningBudgetTokens ?? 0) > 0 {
                provider["require_parameters"] = true
            }
            body["provider"] = provider
        }
        body.merge(extraBody) { _, new in new }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    struct ChatUsage: Equatable {
        var inputTokens: Int
        var outputTokens: Int
        var cachedInputTokens: Int
        var reasoningOutputTokens: Int
    }

    struct ParsedChatCompletion: Equatable {
        var content: String
        var usage: ChatUsage?
    }

    static func parseChatCompletion(_ data: Data) throws -> ParsedChatCompletion {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw TextEngineError.badResponse("unexpected /chat/completions payload")
        }
        if let refusal = (message["refusal"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !refusal.isEmpty {
            throw TextEngineError.badResponse("model refusal: \(String(refusal.prefix(600)))")
        }
        switch choice["finish_reason"] as? String {
        case "length":
            throw TextEngineError.outputTruncated
        case "content_filter":
            throw TextEngineError.badResponse("response was stopped by the content filter")
        default:
            break
        }
        guard let content = message["content"] as? String else {
            throw TextEngineError.badResponse("chat completion contained no text")
        }

        let usageObject = json["usage"] as? [String: Any]
        let inputDetails = usageObject?["prompt_tokens_details"] as? [String: Any]
        let outputDetails = usageObject?["completion_tokens_details"] as? [String: Any]
        let usage = usageObject.map {
            ChatUsage(inputTokens: $0["prompt_tokens"] as? Int ?? 0,
                      outputTokens: $0["completion_tokens"] as? Int ?? 0,
                      cachedInputTokens: inputDetails?["cached_tokens"] as? Int ?? 0,
                      reasoningOutputTokens: outputDetails?["reasoning_tokens"] as? Int ?? 0)
        }
        return ParsedChatCompletion(content: content, usage: usage)
    }

    /// llama-server counts hidden reasoning and visible content inside the same
    /// completion limit. OpenAI exposes a qualitative reasoning effort;
    /// OpenRouter normalizes a provider-independent reasoning object. Generic
    /// compatible servers receive only common request fields.
    nonisolated static func applyGenerationOptions(
        to body: inout [String: Any],
        options: TextGenerationOptions?,
        defaultThinkingBudgetTokens: Int?,
        dialect: ChatCompletionDialect,
        model: String,
        openRouterReasoning: OpenRouterReasoningCompatibility = .native
    ) {
        let maxTokens = options?.maxTokens.map { max(1, $0) }
        let isReasoningModel = supportsOpenAIReasoningEffort(model: model)

        switch dialect {
        case .llamaServer:
            if let maxTokens { body["max_tokens"] = maxTokens }
            if let temperature = options?.temperature {
                body["temperature"] = max(0, temperature)
            }
            guard let requested = options?.reasoningBudgetTokens
                    ?? defaultThinkingBudgetTokens else { return }
            let nonnegative = max(0, requested)
            let effective = maxTokens.map { min(nonnegative, $0 / 2) } ?? nonnegative
            body["thinking_budget_tokens"] = effective

        case .generic:
            if let maxTokens { body["max_tokens"] = maxTokens }
            if let temperature = options?.temperature {
                body["temperature"] = max(0, temperature)
            }

        case .openRouter:
            if let maxTokens { body["max_tokens"] = maxTokens }
            if openRouterReasoning == .highEffort {
                body["reasoning"] = ["effort": "high"]
            } else if let requested = options?.reasoningBudgetTokens {
                let nonnegative = max(0, requested)
                if nonnegative == 0 {
                    body["reasoning"] = ["effort": "none"]
                } else {
                    let effective = maxTokens.map { min(nonnegative, $0 / 2) }
                        ?? nonnegative
                    body["reasoning"] = [
                        "max_tokens": max(1, effective),
                        "exclude": true,
                    ]
                }
            }
            // Sampling controls vary across routed reasoning providers. Keep
            // temperature only for requests that leave reasoning at the model
            // default or explicitly disable it. High-effort fallback is
            // always-on thinking, so omit temperature there too.
            if openRouterReasoning != .highEffort,
               (options?.reasoningBudgetTokens ?? 0) <= 0,
               let temperature = options?.temperature {
                body["temperature"] = max(0, temperature)
            }

        case .openAI:
            if let maxTokens { body["max_completion_tokens"] = maxTokens }
            // Current OpenAI reasoning models reject sampling knobs such as a
            // custom temperature. Non-reasoning chat models still accept it.
            if !isReasoningModel, let temperature = options?.temperature {
                body["temperature"] = max(0, temperature)
            }
            if isReasoningModel,
               let budget = options?.reasoningBudgetTokens,
               budget > 0 {
                body["reasoning_effort"] = reasoningEffort(for: budget)
            }
        }
    }

    /// True when an OpenRouter 404 means the requested reasoning/schema
    /// parameters have no matching endpoint, so one high-effort retry is allowed.
    nonisolated static func shouldFallbackToHighReasoning(
        dialect: ChatCompletionDialect,
        error: Error,
        usedFallback: Bool,
        requestedReasoningBudget: Int?
    ) -> Bool {
        guard dialect == .openRouter,
              !usedFallback,
              requestedReasoningBudget != nil,
              case .httpStatus(let code, let detail, _) = error as? TextEngineError,
              code == 404
        else { return false }
        return detail.localizedCaseInsensitiveContains(
            "no endpoints found that can handle the requested parameters")
    }

    nonisolated static func supportsOpenAIReasoningEffort(model: String) -> Bool {
        let name = model.lowercased()
        return name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4")
            || name.hasPrefix("gpt-5")
    }

    private nonisolated static func reasoningEffort(for tokenBudget: Int) -> String {
        if tokenBudget <= 512 { return "low" }
        if tokenBudget <= 4_096 { return "medium" }
        return "high"
    }

    /// Raw `/v1/completions`: the model continues `request.prompt` directly with
    /// no chat template, which is what cotyping wants. `top_k`/`min_p`/
    /// `repeat_penalty` are llama.cpp extensions a generic server ignores.
    func complete(_ request: CompletionRequest) async throws -> String {
        guard !model.isEmpty else { throw TextEngineError.noModel }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = [
            "model": model,
            "prompt": request.prompt,
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
            "top_p": request.topP,
            "top_k": request.topK,
            "min_p": request.minP,
            "repeat_penalty": request.repeatPenalty,
            "seed": request.seed,
            "stream": false,
        ]
        if !request.stop.isEmpty { body["stop"] = request.stop }
        body.merge(extraBody) { _, new in new }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await cotypingCompletionSend(urlRequest, base: baseURL)
        let httpResponse = response as? HTTPURLResponse
        guard let status = httpResponse?.statusCode, (200...299).contains(status) else {
            throw TextEngineError.fromHTTPResponse(httpResponse, data: data)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let text = choices.first?["text"] as? String else {
            throw TextEngineError.badResponse("unexpected /completions payload")
        }
        return text
    }

    private enum StreamingCompatibilityError: Error {
        case unsupportedPayload
    }

    /// Streaming `/v1/completions` (SSE). Accumulates `choices[].text` deltas,
    /// emitting the running text via `onPartial`. A non-streaming compatibility
    /// fallback is allowed only when a successful response contains no SSE
    /// events; transport and HTTP failures are surfaced without duplicating work.
    func completeStreaming(_ request: CompletionRequest,
                           onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        guard !model.isEmpty else { throw TextEngineError.noModel }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = [
            "model": model,
            "prompt": request.prompt,
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
            "top_p": request.topP,
            "top_k": request.topK,
            "min_p": request.minP,
            "repeat_penalty": request.repeatPenalty,
            "seed": request.seed,
            "stream": true,
        ]
        if !request.stop.isEmpty { body["stop"] = request.stop }
        body.merge(extraBody) { _, new in new }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        var accumulated = ""
        var tokenLikeChunks = 0
        var receivedEvent = false
        var receivedTerminalEvent = false
        var stoppedByPolicy = false
        do {
            let (bytes, response) = try await completionSession.bytes(for: urlRequest)
            let httpResponse = response as? HTTPURLResponse
            guard let status = httpResponse?.statusCode, (200...299).contains(status) else {
                throw TextEngineError.fromHTTPResponse(httpResponse, data: Data())
            }
            for try await line in bytes.lines {
                guard let event = cotypingParseSSEEvent(line) else { continue }
                receivedEvent = true
                if let delta = event.delta, !delta.isEmpty {
                    accumulated += delta
                    tokenLikeChunks += 1
                    onPartial(accumulated)
                    if CotypingDecodeStopPolicy.verdict(
                        accumulated: accumulated,
                        tokensGenerated: tokenLikeChunks
                    ) != nil {
                        stoppedByPolicy = true
                        break
                    }
                }
                if event.isTerminal {
                    receivedTerminalEvent = true
                    break
                }
            }
            if !stoppedByPolicy, !receivedTerminalEvent {
                if !receivedEvent && accumulated.isEmpty {
                    throw StreamingCompatibilityError.unsupportedPayload
                }
                throw TextEngineError.badResponse(
                    "stream ended before a terminal completion event")
            }
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch is StreamingCompatibilityError where accumulated.isEmpty {
            // A 2xx non-SSE response means this server does not implement the
            // streaming contract. No tokens were generated or shown yet.
            let full = try await complete(request)
            onPartial(full)
            return full
        }
        return accumulated
    }
}

private func send(_ request: URLRequest, base: URL) async throws -> (Data, URLResponse) {
    do {
        return try await llmSession.data(for: request)
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
        // Task cancelled mid-request (e.g. the user pressed Stop): surface it as
        // cancellation, not an unreachable-server error, so callers can tell the
        // difference.
        throw CancellationError()
    } catch {
        let diagnostic = error as NSError
        lokalbotLog(
            "text engine transport failure host=\(base.host ?? "unknown") "
                + "domain=\(diagnostic.domain) code=\(diagnostic.code)")
        throw TextEngineError.serverUnreachable(
            base.absoluteString,
            transportCode: diagnostic.code)
    }
}
