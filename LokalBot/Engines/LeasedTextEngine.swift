import Foundation

/// A `TextEngine` decorator that runs every call under an inference lease.
/// Construction stays cheap; the runtime boots on first use and remains
/// pinned against eviction only while a call is active.
struct LeasedTextEngine: TextEngine {
    let base: TextEngine
    let broker: InferenceBroker
    let role: InferenceRole
    let modelURL: URL
    let priority: InferencePriority
    let purpose: String

    var displayName: String { base.displayName }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        try await broker.withLease(role, model: modelURL, priority: priority, purpose: purpose) {
            try await base.generate(system: system, prompt: prompt, context: context)
        }
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any]) async throws -> String {
        try await broker.withLease(role, model: modelURL, priority: priority, purpose: purpose) {
            try await base.generate(system: system, prompt: prompt, context: context,
                                    schema: schema)
        }
    }

    func complete(_ request: CompletionRequest) async throws -> String {
        try await broker.withLease(role, model: modelURL, priority: priority, purpose: purpose) {
            try await base.complete(request)
        }
    }

    func completeStreaming(_ request: CompletionRequest,
                           onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        try await broker.withLease(role, model: modelURL, priority: priority, purpose: purpose) {
            try await base.completeStreaming(request, onPartial: onPartial)
        }
    }
}
