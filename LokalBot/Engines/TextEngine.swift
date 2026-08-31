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
                  schema: JSONObject) async throws -> String
    func generate(system: String, prompt: String, context: [String],
                  schema: JSONObject,
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

/// Shared adapter for HTTP chat backends. Each backend owns one request path;
/// the four public generation overloads only select schema/options.
protocol ChatTextEngine: TextEngine {
    func chat(
        system: String,
        prompt: String,
        context: [String],
        schema: JSONObject?,
        options: TextGenerationOptions?
    ) async throws -> String
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
        if let json = try? JSONValue.decodeObject(from: data),
           let error = json["error"]?.objectValue,
           let message = error["message"]?.stringValue {
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
    static func validationIssue(in schema: JSONObject) -> String? {
        guard schema["type"]?.stringValue == "object" else {
            return "$ must be an object schema"
        }
        return validationIssue(in: schema, path: "$")
    }

    private static func validationIssue(in node: JSONObject, path: String) -> String? {
        anyOfIssue(in: node, path: path)
            ?? objectIssue(in: node, path: path)
            ?? arrayIssue(in: node, path: path)
            ?? definitionsIssue(in: node, path: path)
    }

    private static func anyOfIssue(in node: JSONObject, path: String) -> String? {
        if let variants = node["anyOf"]?.objectArrayValue {
            for (index, variant) in variants.enumerated() {
                if let issue = validationIssue(in: variant, path: "\(path).anyOf[\(index)]") {
                    return issue
                }
            }
        }
        return nil
    }

    private static func objectIssue(in node: JSONObject, path: String) -> String? {
        guard schema(node, containsType: "object") else { return nil }
        guard node["additionalProperties"]?.boolValue == false else {
            return "\(path) must set additionalProperties to false"
        }
        guard let properties = node["properties"]?.objectValue else {
            return "\(path) must declare properties"
        }
        let required = Set(node["required"]?.stringArrayValue ?? [])
        let propertyNames = Set(properties.keys)
        guard required == propertyNames else {
            let missing = propertyNames.subtracting(required).sorted().joined(separator: ", ")
            return "\(path) must require every property; missing: \(missing)"
        }
        for name in properties.keys.sorted() {
            guard let property = properties[name]?.objectValue else {
                return "\(path).properties.\(name) is not a schema object"
            }
            if let issue = validationIssue(in: property, path: "\(path).properties.\(name)") {
                return issue
            }
        }
        return nil
    }

    private static func arrayIssue(in node: JSONObject, path: String) -> String? {
        guard schema(node, containsType: "array") else { return nil }
        guard let items = node["items"]?.objectValue else {
            return "\(path) must declare array items"
        }
        return validationIssue(in: items, path: "\(path).items")
    }

    private static func definitionsIssue(in node: JSONObject, path: String) -> String? {
        if let definitions = node["$defs"]?.objectValue {
            for name in definitions.keys.sorted() {
                guard let definition = definitions[name]?.objectValue else {
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

    private static func schema(_ node: JSONObject, containsType type: String) -> Bool {
        node["type"]?.stringValue == type
            || node["type"]?.stringArrayValue?.contains(type) == true
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
          let json = try? JSONValue.decodeObject(from: data),
          let choice = json["choices"]?.objectArrayValue?.first else { return nil }
    let finishReason = choice["finish_reason"]?.stringValue
    return CotypingSSEEvent(delta: choice["text"]?.stringValue,
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
                  schema: JSONObject) async throws -> String {
        try await generate(system: system, prompt: prompt, context: context)
    }

    /// Backends that cannot combine grammar constraints with request controls
    /// still preserve the schema. Built-in llama-server and Ollama override
    /// this path so digest extraction also gets its explicit sampling policy.
    func generate(system: String, prompt: String, context: [String],
                  schema: JSONObject,
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

extension ChatTextEngine {
    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        try await chat(system: system, prompt: prompt, context: context, schema: nil, options: nil)
    }

    func generate(system: String, prompt: String, context: [String],
                  options: TextGenerationOptions) async throws -> String {
        try await chat(
            system: system, prompt: prompt, context: context,
            schema: nil, options: options)
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: JSONObject) async throws -> String {
        try await chat(
            system: system, prompt: prompt, context: context,
            schema: schema, options: nil)
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: JSONObject,
                  options: TextGenerationOptions) async throws -> String {
        try await chat(
            system: system, prompt: prompt, context: context,
            schema: schema, options: options)
    }
}

// MARK: - Ollama

struct OllamaEngine: ChatTextEngine {
    var baseURL: URL
    var model: String

    var displayName: String { "Ollama — \(model)" }

    /// Ollama enforces JSON schemas natively via the `format` field.
    func chat(system: String, prompt: String, context: [String],
              schema: JSONObject?,
              options: TextGenerationOptions?) async throws -> String {
        guard !model.isEmpty else { throw TextEngineError.noModel }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let user = (context + [prompt]).joined(separator: "\n\n")
        var body: JSONObject = [
            "model": .string(model),
            "stream": false,
            "messages": .array([
                .object(["role": "system", "content": .string(system)]),
                .object(["role": "user", "content": .string(user)]),
            ]),
        ]
        if let schema { body["format"] = .object(schema) }
        var generationOptions: JSONObject = [:]
        if let maxTokens = options?.maxTokens {
            generationOptions["num_predict"] = .number(Double(max(1, maxTokens)))
        }
        if let temperature = options?.temperature {
            generationOptions["temperature"] = .number(max(0, temperature))
        }
        if !generationOptions.isEmpty { body["options"] = .object(generationOptions) }
        request.httpBody = try JSONValue.encodeObject(body)

        let (data, response) = try await send(request, base: baseURL)
        let httpResponse = response as? HTTPURLResponse
        guard let status = httpResponse?.statusCode, (200...299).contains(status) else {
            throw TextEngineError.fromHTTPResponse(httpResponse, data: data)
        }
        let json = try JSONValue.decodeObject(from: data)
        guard let message = json["message"]?.objectValue,
              let content = message["content"]?.stringValue else {
            throw TextEngineError.badResponse("unexpected /api/chat payload")
        }
        return strippingReasoning(content)
    }

    /// Model names from `GET /api/tags`; empty array if the server is down.
    static func listModels(baseURL: URL) async -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        guard let (data, _) = try? await llmSession.data(for: request),
              let json = try? JSONValue.decodeObject(from: data),
              let models = json["models"]?.objectArrayValue else { return [] }
        return models.compactMap { $0["name"]?.stringValue }.sorted()
    }
}

// MARK: - OpenAI-compatible localhost (LM Studio, vllm-mlx, …)

struct OpenAICompatibleEngine: ChatTextEngine {
    var baseURL: URL        // e.g. http://localhost:1234/v1
    var model: String
    var apiKey: String?
    /// Extra top-level request fields for server-specific compatibility.
    var extraBody: JSONObject = [:]
    var chatDialect: ChatCompletionDialect = .generic
    var openRouterDataPolicy: OpenRouterDataPolicy = .privateOnly
    /// llama-server's request-level thinking ceiling. Kept nil for generic
    /// external endpoints that may not understand this extension.
    var defaultThinkingBudgetTokens: Int?
    var displayNameOverride: String?

    var displayName: String { displayNameOverride ?? "OpenAI-compatible — \(model)" }

    /// OpenAI-standard structured output: llama-server compiles the schema to
    /// a GBNF grammar and constrains decoding; LM Studio / vllm honour the
    /// same `response_format` shape.
    func chat(system: String, prompt: String, context: [String],
              schema: JSONObject?,
              options: TextGenerationOptions?) async throws -> String {
        try await chat(
            system: system, prompt: prompt, context: context,
            schema: schema, options: options, openRouterReasoning: .native)
    }

    private func chat(system: String, prompt: String, context: [String],
                      schema: JSONObject?,
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
                requestedSchema: schema != nil,
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
                         schema: JSONObject?,
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
        var body: JSONObject = [
            "model": .string(model),
            "messages": .array([
                .object(["role": "system", "content": .string(system)]),
                .object(["role": "user", "content": .string(user)]),
            ]),
        ]
        if let schema, !(chatDialect == .openRouter && openRouterReasoning == .highEffort) {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "response",
                    "strict": true,
                    "schema": .object(schema),
                ],
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
            var provider: JSONObject = [
                "data_collection": .string(openRouterDataPolicy.providerDataCollectionValue),
            ]
            if openRouterReasoning != .highEffort,
               schema != nil || (options?.reasoningBudgetTokens ?? 0) > 0 {
                provider["require_parameters"] = true
            }
            body["provider"] = .object(provider)
        }
        body.merge(extraBody) { _, new in new }
        request.httpBody = try JSONValue.encodeObject(body)
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
        guard let json = try? JSONValue.decodeObject(from: data),
              let choice = json["choices"]?.objectArrayValue?.first,
              let message = choice["message"]?.objectValue else {
            throw TextEngineError.badResponse("unexpected /chat/completions payload")
        }
        if let refusal = message["refusal"]?.stringValue?.trimmingCharacters(
            in: .whitespacesAndNewlines), !refusal.isEmpty {
            throw TextEngineError.badResponse("model refusal: \(String(refusal.prefix(600)))")
        }
        switch choice["finish_reason"]?.stringValue {
        case "length":
            throw TextEngineError.outputTruncated
        case "content_filter":
            throw TextEngineError.badResponse("response was stopped by the content filter")
        default:
            break
        }
        guard let content = message["content"]?.stringValue else {
            throw TextEngineError.badResponse("chat completion contained no text")
        }

        let usageObject = json["usage"]?.objectValue
        let inputDetails = usageObject?["prompt_tokens_details"]?.objectValue
        let outputDetails = usageObject?["completion_tokens_details"]?.objectValue
        let usage = usageObject.map {
            ChatUsage(inputTokens: $0["prompt_tokens"]?.intValue ?? 0,
                      outputTokens: $0["completion_tokens"]?.intValue ?? 0,
                      cachedInputTokens: inputDetails?["cached_tokens"]?.intValue ?? 0,
                      reasoningOutputTokens: outputDetails?["reasoning_tokens"]?.intValue ?? 0)
        }
        return ParsedChatCompletion(content: content, usage: usage)
    }

    /// llama-server counts hidden reasoning and visible content inside the same
    /// completion limit. OpenAI exposes a qualitative reasoning effort;
    /// OpenRouter normalizes a provider-independent reasoning object. Generic
    /// compatible servers receive only common request fields.
    nonisolated static func applyGenerationOptions(
        to body: inout JSONObject,
        options: TextGenerationOptions?,
        defaultThinkingBudgetTokens: Int?,
        dialect: ChatCompletionDialect,
        model: String,
        openRouterReasoning: OpenRouterReasoningCompatibility = .native
    ) {
        let maxTokens = options?.maxTokens.map { max(1, $0) }
        switch dialect {
        case .llamaServer:
            applyLlamaServerOptions(
                to: &body,
                options: options,
                maxTokens: maxTokens,
                defaultThinkingBudgetTokens: defaultThinkingBudgetTokens)
        case .generic:
            applyCommonSamplingOptions(to: &body, options: options, maxTokens: maxTokens)
        case .openRouter:
            applyOpenRouterOptions(
                to: &body,
                options: options,
                maxTokens: maxTokens,
                reasoningCompatibility: openRouterReasoning)
        case .openAI:
            applyOpenAIOptions(
                to: &body,
                options: options,
                maxTokens: maxTokens,
                model: model)
        }
    }

    private nonisolated static func applyCommonSamplingOptions(
        to body: inout JSONObject,
        options: TextGenerationOptions?,
        maxTokens: Int?
    ) {
        if let maxTokens { body["max_tokens"] = .number(Double(maxTokens)) }
        if let temperature = options?.temperature {
            body["temperature"] = .number(max(0, temperature))
        }
    }

    private nonisolated static func applyLlamaServerOptions(
        to body: inout JSONObject,
        options: TextGenerationOptions?,
        maxTokens: Int?,
        defaultThinkingBudgetTokens: Int?
    ) {
        applyCommonSamplingOptions(to: &body, options: options, maxTokens: maxTokens)
        guard let requested = options?.reasoningBudgetTokens
                ?? defaultThinkingBudgetTokens else { return }
        let nonnegative = max(0, requested)
        let effective = maxTokens.map {
            min(nonnegative, $0 / 2)
        } ?? nonnegative
        body["thinking_budget_tokens"] = .number(Double(effective))
    }

    private nonisolated static func applyOpenRouterOptions(
        to body: inout JSONObject,
        options: TextGenerationOptions?,
        maxTokens: Int?,
        reasoningCompatibility: OpenRouterReasoningCompatibility
    ) {
        if let maxTokens { body["max_tokens"] = .number(Double(maxTokens)) }
        applyOpenRouterReasoning(
            to: &body,
            requestedBudget: options?.reasoningBudgetTokens,
            maxTokens: maxTokens,
            compatibility: reasoningCompatibility)
        // Routed reasoning providers do not share sampling controls.
        if reasoningCompatibility != .highEffort,
           (options?.reasoningBudgetTokens ?? 0) <= 0,
           let temperature = options?.temperature {
            body["temperature"] = .number(max(0, temperature))
        }
    }

    private nonisolated static func applyOpenRouterReasoning(
        to body: inout JSONObject,
        requestedBudget: Int?,
        maxTokens: Int?,
        compatibility: OpenRouterReasoningCompatibility
    ) {
        if compatibility == .highEffort {
            body["reasoning"] = ["effort": "high"]
            return
        }
        guard let requestedBudget else { return }
        let nonnegative = max(0, requestedBudget)
        guard nonnegative > 0 else {
            body["reasoning"] = ["effort": "none"]
            return
        }
        let effective = maxTokens.map { min(nonnegative, $0 / 2) } ?? nonnegative
        body["reasoning"] = [
            "max_tokens": .number(Double(max(1, effective))),
            "exclude": true,
        ]
    }

    private nonisolated static func applyOpenAIOptions(
        to body: inout JSONObject,
        options: TextGenerationOptions?,
        maxTokens: Int?,
        model: String
    ) {
        if let maxTokens { body["max_completion_tokens"] = .number(Double(maxTokens)) }
        let isReasoningModel = supportsOpenAIReasoningEffort(model: model)
        if !isReasoningModel, let temperature = options?.temperature {
            body["temperature"] = .number(max(0, temperature))
        }
        if isReasoningModel,
           let budget = options?.reasoningBudgetTokens,
           budget > 0 {
            body["reasoning_effort"] = .string(reasoningEffort(for: budget))
        }
    }

    /// True when OpenRouter rejects the requested reasoning/schema combination,
    /// so one high-effort retry without strict structured-output requirements is
    /// allowed. Some always-reasoning models report this as a parameter-routing
    /// 404; others return a 400 when `effort: none` is explicit.
    nonisolated static func shouldFallbackToHighReasoning(
        dialect: ChatCompletionDialect,
        error: Error,
        usedFallback: Bool,
        requestedSchema: Bool,
        requestedReasoningBudget: Int?
    ) -> Bool {
        guard dialect == .openRouter,
              !usedFallback,
              requestedSchema || requestedReasoningBudget != nil,
              case .httpStatus(let code, let detail, _) = error as? TextEngineError
        else { return false }

        if code == 404 {
            return detail.localizedCaseInsensitiveContains(
                "no endpoints found that can handle the requested parameters")
        }
        guard code == 400, requestedReasoningBudget == 0 else { return false }
        return detail.localizedCaseInsensitiveContains("reasoning is mandatory")
            && detail.localizedCaseInsensitiveContains("cannot be disabled")
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
        var body: JSONObject = [
            "model": .string(model),
            "prompt": .string(request.prompt),
            "max_tokens": .number(Double(request.maxTokens)),
            "temperature": .number(request.temperature),
            "top_p": .number(request.topP),
            "top_k": .number(Double(request.topK)),
            "min_p": .number(request.minP),
            "repeat_penalty": .number(request.repeatPenalty),
            "seed": .number(Double(request.seed)),
            "stream": false,
        ]
        if !request.stop.isEmpty { body["stop"] = .array(request.stop.map(JSONValue.string)) }
        body.merge(extraBody) { _, new in new }
        urlRequest.httpBody = try JSONValue.encodeObject(body)

        let (data, response) = try await cotypingCompletionSend(urlRequest, base: baseURL)
        let httpResponse = response as? HTTPURLResponse
        guard let status = httpResponse?.statusCode, (200...299).contains(status) else {
            throw TextEngineError.fromHTTPResponse(httpResponse, data: data)
        }
        let json = try JSONValue.decodeObject(from: data)
        guard let choices = json["choices"]?.objectArrayValue,
              let text = choices.first?["text"]?.stringValue else {
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
        var body: JSONObject = [
            "model": .string(model),
            "prompt": .string(request.prompt),
            "max_tokens": .number(Double(request.maxTokens)),
            "temperature": .number(request.temperature),
            "top_p": .number(request.topP),
            "top_k": .number(Double(request.topK)),
            "min_p": .number(request.minP),
            "repeat_penalty": .number(request.repeatPenalty),
            "seed": .number(Double(request.seed)),
            "stream": true,
        ]
        if !request.stop.isEmpty { body["stop"] = .array(request.stop.map(JSONValue.string)) }
        body.merge(extraBody) { _, new in new }
        urlRequest.httpBody = try JSONValue.encodeObject(body)

        do {
            return try await collectStreamingCompletion(urlRequest, onPartial: onPartial)
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch is StreamingCompatibilityError {
            // A 2xx non-SSE response means this server does not implement the
            // streaming contract. No tokens were generated or shown yet.
            let full = try await complete(request)
            onPartial(full)
            return full
        }
    }

    private func collectStreamingCompletion(
        _ urlRequest: URLRequest,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var accumulated = ""
        var tokenLikeChunks = 0
        var receivedEvent = false
        var receivedTerminalEvent = false
        var stoppedByPolicy = false
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
            guard receivedEvent || !accumulated.isEmpty else {
                throw StreamingCompatibilityError.unsupportedPayload
            }
            throw TextEngineError.badResponse(
                "stream ended before a terminal completion event")
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
