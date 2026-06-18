import Foundation

/// Summarization / day digests / Q&A (design doc §5). Both backends speak
/// HTTP to localhost only — the model itself runs in Ollama, LM Studio, or
/// any OpenAI-compatible server the user points us at.
protocol TextEngine {
    var displayName: String { get }
    func generate(system: String, prompt: String, context: [String]) async throws -> String
}

enum TextEngineError: LocalizedError {
    case serverUnreachable(String)
    case badResponse(String)
    case noModel
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .serverUnreachable(let base):
            "Can't reach \(base). Is the server running? (e.g. `ollama serve`)"
        case .badResponse(let detail):
            "LLM server error: \(detail)"
        case .noModel:
            "No summarization model selected. Pick one in Settings → Models."
        case .unavailable(let detail):
            detail
        }
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

// MARK: - Ollama

struct OllamaEngine: TextEngine {
    var baseURL: URL
    var model: String

    var displayName: String { "Ollama — \(model)" }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        guard !model.isEmpty else { throw TextEngineError.noModel }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let user = (context + [prompt]).joined(separator: "\n\n")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request, base: baseURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TextEngineError.badResponse(String(data: data, encoding: .utf8) ?? "HTTP error")
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
    /// Extra top-level request fields (e.g. llama-server's
    /// chat_template_kwargs to disable Qwen3 thinking).
    var extraBody: [String: Any] = [:]
    var displayNameOverride: String?

    var displayName: String { displayNameOverride ?? "OpenAI-compatible — \(model)" }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        guard !model.isEmpty else { throw TextEngineError.noModel }
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
        body.merge(extraBody) { _, new in new }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request, base: baseURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TextEngineError.badResponse(String(data: data, encoding: .utf8) ?? "HTTP error")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TextEngineError.badResponse("unexpected /chat/completions payload")
        }
        return strippingReasoning(content)
    }
}

private func send(_ request: URLRequest, base: URL) async throws -> (Data, URLResponse) {
    do {
        return try await llmSession.data(for: request)
    } catch {
        throw TextEngineError.serverUnreachable(base.absoluteString)
    }
}
