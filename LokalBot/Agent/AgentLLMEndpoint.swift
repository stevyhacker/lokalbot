import Foundation

/// A resolved OpenAI-compatible endpoint the agent's provider will talk to.
struct AgentLLMEndpoint: Equatable, Sendable {
    let baseURL: URL
    let model: String
    let contextTokens: Int
    let apiKey: String?

    /// Matches the built-in Main LLM and gives Agent Mode the same compaction
    /// boundary. External endpoints use it as a conservative declared window
    /// when their true model metadata is unavailable.
    static let defaultContextTokens = MainLLMRuntimePolicy.contextTokens
}

enum AgentLLMResolution: Equatable, Sendable {
    /// Caller resolves the model URL and holds an `InferenceBroker` Main LLM
    /// lease before building the endpoint from the shared base URL + model id.
    case builtIn(modelID: String)
    case ready(AgentLLMEndpoint)
    case unsupported(reason: String)
}
