import Foundation

/// Per-completion router between the in-process `LocalLlamaCotypingEngine`
/// (built-in GGUF on Apple Silicon, flag on) and the existing HTTP
/// `CotypingEngine` (non-GGUF backends, flag off, or in-process load failure).
/// Conforms to `CotypingCompleting`, so `CotypingCoordinator` is unchanged.
@MainActor
final class CotypingEngineSelector: CotypingCompleting {
    private let http: CotypingCompleting
    private let makeLocal: (String) -> LocalLlamaCotypingEngine
    private let settings: () -> AppSettings
    private let storage: StorageManager
    private var local: LocalLlamaCotypingEngine?
    private var localModelPath: String?
    /// Set after the first in-process failure so the HTTP fallback is logged
    /// once per failure episode (spec §13), not on every keystroke. Reset on a
    /// successful local generation or a model-path change.
    private var didLogLocalFailure = false

    init(
        http: CotypingCompleting,
        makeLocal: @escaping (String) -> LocalLlamaCotypingEngine,
        settings: @escaping () -> AppSettings,
        storage: StorageManager
    ) {
        self.http = http
        self.makeLocal = makeLocal
        self.settings = settings
        self.storage = storage
    }

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    nonisolated static func shouldUseLocal(settings: AppSettings, modelURL: URL?, isAppleSilicon: Bool) -> Bool {
        settings.cotypingInProcessRuntime && isAppleSilicon && modelURL != nil
    }

    /// Resolves the built-in cotyping model path the same way `makeTextEngine` does.
    private func resolvedModelURL(_ s: AppSettings) -> URL? {
        guard let entry = ModelCatalog.entry(id: s.cotypingBuiltInModelID, custom: s.customBuiltInModels)
                ?? ModelCatalog.entry(id: ModelCatalog.bundledID) else { return nil }
        return ModelCatalog.localURL(for: entry, storage: storage)
    }

    /// Returns the local engine if eligible, lazily (re)building it when the
    /// resolved model path changes; nil → use HTTP.
    private func localIfEligible() -> LocalLlamaCotypingEngine? {
        let s = settings()
        guard let url = resolvedModelURL(s),
              Self.shouldUseLocal(settings: s, modelURL: url, isAppleSilicon: Self.isAppleSilicon)
        else { return nil }
        if local == nil || localModelPath != url.path {
            local = makeLocal(url.path)
            localModelPath = url.path
            didLogLocalFailure = false
        }
        return local
    }

    func prewarm() async {
        guard let engine = localIfEligible() else { return }
        try? await engine.prewarm()
    }

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        guard let engine = localIfEligible() else { return try await http.generate(request) }
        do {
            let result = try await engine.generate(request)
            didLogLocalFailure = false
            return result
        } catch let error as LlamaRuntimeError {
            logLocalFallback(error)
            return try await http.generate(request)
        }
    }

    func generateStreaming(
        _ request: CotypingRequest,
        onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void
    ) async throws -> CotypingNormalizationResult {
        guard let engine = localIfEligible() else {
            return try await http.generateStreaming(request, onPartial: onPartial)
        }
        do {
            let result = try await engine.generateStreaming(request, onPartial: onPartial)
            didLogLocalFailure = false
            return result
        } catch let error as LlamaRuntimeError {
            logLocalFallback(error)
            return try await http.generateStreaming(request, onPartial: onPartial)
        }
    }

    /// Logs the in-process→HTTP fallback once per failure episode (spec §13).
    /// The local engine is kept (not torn down) so a transient failure — e.g. a
    /// memory-pressure unload (Task 8) — recovers on a later completion, and the
    /// log does not repeat on every keystroke.
    private func logLocalFallback(_ error: LlamaRuntimeError) {
        guard !didLogLocalFailure else { return }
        didLogLocalFailure = true
        NSLog("Cotyping: in-process runtime unavailable (\(error)); using HTTP fallback (will keep retrying).")
    }
}
