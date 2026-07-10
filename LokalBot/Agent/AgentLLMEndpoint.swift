import Foundation

/// A resolved OpenAI-compatible endpoint the agent's provider will talk to.
struct AgentLLMEndpoint: Equatable {
    let baseURL: URL
    let model: String
    let contextTokens: Int
    let apiKey: String?

    /// Matches LlamaServer.shared's context size; also a sane compaction
    /// threshold for external endpoints whose true window we can't know.
    static let defaultContextTokens = 16_384
}

enum AgentLLMResolution: Equatable {
    /// Caller must `LlamaServer.shared.ensureRunning(modelAt:)` first, then
    /// build the endpoint from `LlamaServer.shared.baseURL` + this model id.
    case builtIn(modelID: String)
    case ready(AgentLLMEndpoint)
    case unsupported(reason: String)
}

/// Pure settings → endpoint resolution for Agent Mode. Mirrors the backend
/// switch in ProcessingPipeline.makeTextEngine, with deliberate differences:
/// no async work here (server startup is the caller's job); Ollama and the
/// OpenAI-compatible server each require an explicit model because pi
/// registers the model id statically at launch; and an empty API key
/// resolves to nil.
enum AgentLLMEndpointResolver {

    static func resolve(settings: AppSettings) -> AgentLLMResolution {
        switch settings.summarizerBackend {
        case .builtIn:
            guard let entry = ModelCatalog.entry(id: settings.builtInModelID,
                                                 custom: settings.customBuiltInModels)
                    ?? ModelCatalog.entry(id: ModelCatalog.recommendedSummarizationID) else {
                return .unsupported(reason: "No built-in model is configured. Pick one under Settings → Models.")
            }
            return .builtIn(modelID: entry.id)

        case .appleIntelligence:
            return .unsupported(reason: "Apple Intelligence doesn't expose a local endpoint Agent Mode can use. Switch the Main LLM engine to Built-in llama.cpp (or Ollama / an OpenAI-compatible server) under Settings → Models.")

        case .ollama:
            guard let base = URL(string: settings.ollamaBaseURL) else {
                return .unsupported(reason: "The Ollama server URL under Settings → Models isn't a valid URL.")
            }
            guard !settings.ollamaModel.isEmpty else {
                return .unsupported(reason: "Pick an Ollama model under Settings → Models — Agent Mode needs an explicit model.")
            }
            return .ready(AgentLLMEndpoint(
                baseURL: base.appendingPathComponent("v1"),
                model: settings.ollamaModel,
                contextTokens: AgentLLMEndpoint.defaultContextTokens,
                apiKey: nil))

        case .openAICompatible:
            guard let base = URL(string: settings.openAIBaseURL) else {
                return .unsupported(reason: "The server URL under Settings → Models isn't a valid URL.")
            }
            guard !settings.openAIModel.isEmpty else {
                return .unsupported(reason: "Set a model name for the OpenAI-compatible server under Settings → Models.")
            }
            let key = settings.openAIAPIKey
            return .ready(AgentLLMEndpoint(
                baseURL: base,
                model: settings.openAIModel,
                contextTokens: AgentLLMEndpoint.defaultContextTokens,
                apiKey: key.isEmpty ? nil : key))
        }
    }
}
