import Foundation

/// Optional personalization folded into the cotyping prompt's conditioning
/// preface. Sourced from settings; all fields are opt-in.
struct CotypingPersonalization: Sendable, Equatable {
    var userName: String?
    var styleNote: String?
    var languageHint: String?
    var isMultiLine: Bool
    /// Condition the prompt on the focused app + window title / field placeholder.
    var appContextEnabled: Bool

    static let none = CotypingPersonalization(
        userName: nil, styleNote: nil, languageHint: nil,
        isMultiLine: false, appContextEnabled: false)
}

/// Pure assembly of a `CotypingRequest` from a focused field. Separated from the
/// I/O engine so request construction is unit-testable without a model.
enum CotypingRequestBuilder {
    /// Returns `nil` when the field has no usable context (blank before caret).
    static func build(
        field: CotypingField,
        config: CotypingConfiguration,
        personalization: CotypingPersonalization,
        generation: UInt64
    ) -> CotypingRequest? {
        guard CotypingPrefixWindow.shouldGenerate(for: field.precedingText) else { return nil }
        let prefix = CotypingPrefixWindow.truncatedPrefix(
            from: field.precedingText,
            maxCharacters: config.maxPrefixCharacters,
            maxWords: config.maxPrefixWords)
        let surfaceLines: [String]
        if personalization.appContextEnabled,
           let surface = CotypingSurfaceComposer.compose(
               appName: field.appName, bundleID: field.bundleID,
               windowTitle: field.windowTitle, fieldPlaceholder: field.fieldPlaceholder) {
            surfaceLines = CotypingSurfaceComposer.prefaceLines(for: surface)
        } else {
            surfaceLines = []
        }
        let prompt = CotypingPromptRenderer.prompt(
            prefixText: prefix,
            surfaceLines: surfaceLines,
            userName: personalization.userName,
            styleNote: personalization.styleNote,
            languageHint: personalization.languageHint)
        return CotypingRequest(
            prompt: prompt,
            prefixText: prefix,
            trailingText: field.trailingText,
            isMultiLine: personalization.isMultiLine,
            maxTokens: config.maxResponseTokens,
            temperature: config.temperature,
            topP: config.topP,
            topK: config.topK,
            minP: config.minP,
            repeatPenalty: config.repeatPenalty,
            seed: config.seed,
            generation: generation)
    }
}

/// The I/O seam: turn a built request into normalized ghost text. Behind a
/// protocol so the coordinator and the in-app preview can run against a fake in
/// tests without a live server.
@MainActor
protocol CotypingCompleting: AnyObject {
    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult
}

/// Production engine: resolves LokalBot's configured `TextEngine` (the very same
/// backend used for summarization — built-in llama-server by default, or Ollama
/// / OpenAI-compatible / Apple Intelligence) and runs one raw completion through
/// the shared normalizer.
@MainActor
final class CotypingEngine: CotypingCompleting {
    /// Resolves the active `TextEngine`. In production this is
    /// `ProcessingPipeline.makeTextEngine(settings)`, which also boots the
    /// built-in llama-server with the selected model on first use.
    private let makeEngine: () async throws -> TextEngine

    init(makeEngine: @escaping () async throws -> TextEngine) {
        self.makeEngine = makeEngine
    }

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        let engine = try await makeEngine()
        let completion = CompletionRequest(
            prompt: request.prompt,
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            topK: request.topK,
            minP: request.minP,
            repeatPenalty: request.repeatPenalty,
            seed: request.seed,
            // Single-line mode stops the server at the first newline; the
            // normalizer still collapses defensively.
            stop: request.isMultiLine ? [] : ["\n"])
        let raw = try await engine.complete(completion)
        return CotypingTextNormalizer.normalizeDetailed(raw, for: request)
    }
}
