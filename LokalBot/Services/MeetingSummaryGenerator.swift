import Foundation

/// Shared model context policy and cleanup of pre-unified checkpoints.
enum MeetingSummaryGenerator {
    static let builtInContextTokens = MainLLMRuntimePolicy.contextTokens
    static let conservativeExternalContextTokens = 16_384

    static func contextTokenLimit(for backend: AppSettings.SummarizerBackend) -> Int {
        backend == .builtIn ? builtInContextTokens : conservativeExternalContextTokens
    }

    static func removeCheckpoint(in folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("summary.parts.partial.json"))
        MeetingNotesGenerator.removeCheckpoint(in: folder)
    }
}
