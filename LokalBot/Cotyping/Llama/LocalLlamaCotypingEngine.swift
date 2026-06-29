import Foundation

/// In-process `CotypingCompleting` conformer. Tokenizes the already-built
/// prompt, drives `LlamaCotypingRuntime`, and reuses the EXACT same
/// normalization + decode-stop policy as the HTTP engine so suggestions are
/// shaped identically. Stops on the stop policy, the token budget, or task
/// cancellation (superseded keystroke).
@MainActor
final class LocalLlamaCotypingEngine: CotypingCompleting {
    private let runtime: LlamaCotypingRuntime
    private let modelPath: String
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(runtime: LlamaCotypingRuntime, modelPath: String) {
        self.runtime = runtime
        self.modelPath = modelPath

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [runtime] in
            Task { await runtime.handleMemoryPressure() }
        }
        source.resume()
        self.memoryPressureSource = source
    }

    deinit { memoryPressureSource?.cancel() }

    /// Loads + primes the model so the first keystroke isn't cold.
    func prewarm() async throws {
        try await runtime.prewarm(modelPath: modelPath)
    }

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        try await run(request) { _ in }
    }

    func generateStreaming(
        _ request: CotypingRequest,
        onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void
    ) async throws -> CotypingNormalizationResult {
        try await run(request, onPartial: onPartial)
    }

    private func run(
        _ request: CotypingRequest,
        onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void
    ) async throws -> CotypingNormalizationResult {
        try await runtime.loadIfNeeded(modelPath: modelPath)
        let promptTokens = await runtime.tokenize(request.prompt, addBOS: true)
        guard !promptTokens.isEmpty else {
            return CotypingNormalizationResult(text: "", suppression: .emptyGeneration)
        }

        let specs = LlamaSamplerSpec.specs(
            temperature: Float(request.temperature),
            topK: Int32(request.topK),
            topP: Float(request.topP),
            minP: Float(request.minP),
            repeatPenalty: Float(request.repeatPenalty),
            repeatLastN: 64,
            seed: UInt32(truncatingIfNeeded: request.seed))

        let accumulator = TokenAccumulator()
        let raw = await runtime.generate(
            promptTokens: promptTokens,
            maxTokens: request.maxTokens,
            samplerSpecs: specs
        ) { piece in
            if Task.isCancelled { return false }
            accumulator.append(piece)
            let result = CotypingTextNormalizer.normalizeDetailed(accumulator.raw, for: request)
            onPartial(result)
            // Native decode-stop at the SAME boundary the HTTP path stops at.
            if CotypingDecodeStopPolicy.verdict(
                accumulated: accumulator.raw,
                tokensGenerated: accumulator.count) != nil {
                return false
            }
            return true
        }

        if Task.isCancelled { throw CancellationError() }
        return CotypingTextNormalizer.normalizeDetailed(raw, for: request)
    }
}

/// Reference-typed accumulator the decode closure mutates across token calls.
/// The runtime invokes `onToken` serially on one thread, so no synchronization
/// is required; marked `@unchecked Sendable` only to cross the actor boundary.
private final class TokenAccumulator: @unchecked Sendable {
    private(set) var raw = ""
    private(set) var count = 0
    func append(_ piece: String) { raw += piece; count += 1 }
}
