import Foundation

/// Shared model context policy and cleanup of pre-unified checkpoints.
enum MeetingSummaryGenerator {
    static let builtInContextTokens = MainLLMRuntimePolicy.contextTokens
    static let conservativeExternalContextTokens = 16_384

    static func contextTokenLimit(for backend: AppSettings.SummarizerBackend) -> Int {
        backend == .builtIn ? builtInContextTokens : conservativeExternalContextTokens
    }

    static func contextTokenLimit(for config: AppSettings) -> Int {
        // Verified OpenRouter GLM-5.3 endpoints offer at least 256K context.
        // Use only 32K, still guarded by conservative byte counts when the
        // provider has no tokenizer. Unknown/custom servers retain 16K.
        if config.summarizerBackend == .openAICompatible,
           let url = URL(string: config.openAIBaseURL),
           ChatCompletionDialect.inferred(from: url) == .openRouter,
           ["z-ai/glm-5.3", "z-ai/glm-5.3-flash"].contains(config.openAIModel.lowercased()) {
            return 32_768
        }
        return contextTokenLimit(for: config.summarizerBackend)
    }

    static func removeCheckpoint(in folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("summary.parts.partial.json"))
        MeetingNotesGenerator.removeCheckpoint(in: folder)
    }
}
