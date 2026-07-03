import Foundation

/// Per-completion router between the in-process `LocalLlamaCotypingEngine`
/// (built-in GGUF on Apple Silicon, flag on) and the existing HTTP
/// `CotypingEngine` (non-GGUF backends, flag off, or in-process load failure).
/// Conforms to `CotypingCompleting`, so `CotypingCoordinator` is unchanged.
@MainActor
final class CotypingEngineSelector: CotypingCompleting {
    /// How long completions stay on HTTP after an in-process failure before
    /// the local engine is rebuilt and retried. Long enough that a persistent
    /// failure doesn't reload the ~6.66 GB weights on every keystroke, short
    /// enough that a transient one (memory pressure passing) recovers soon.
    static let localRetryCooldown: TimeInterval = 60

    private let http: CotypingCompleting
    private let makeLocal: (String) -> CotypingCompleting
    private let settings: () -> AppSettings
    private let storage: StorageManager
    private let now: () -> Date
    private var local: CotypingCompleting?
    private var localModelPath: String?
    /// Set after the first in-process failure so the HTTP fallback is logged
    /// once per failure episode (spec §13), not on every keystroke. Reset on a
    /// successful local generation or a model-path change.
    private var didLogLocalFailure = false
    /// Non-nil while a failure cooldown is active: `localIfEligible()` routes
    /// to HTTP (without rebuilding the local engine) until this instant.
    private var retryLocalAt: Date?

    init(
        http: CotypingCompleting,
        makeLocal: @escaping (String) -> CotypingCompleting,
        settings: @escaping () -> AppSettings,
        storage: StorageManager,
        now: @escaping () -> Date = { Date() }
    ) {
        self.http = http
        self.makeLocal = makeLocal
        self.settings = settings
        self.storage = storage
        self.now = now
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
                ?? ModelCatalog.entry(id: ModelCatalog.recommendedCotypingID) else { return nil }
        return ModelCatalog.localURL(for: entry, storage: storage)
    }

    /// Returns the local engine if eligible, lazily (re)building it when the
    /// resolved model path changes; nil → use HTTP.
    private func localIfEligible() -> CotypingCompleting? {
        let s = settings()
        // Short-circuit the cheap gating conditions before the synchronous GGUF
        // disk read in `resolvedModelURL`: a built-in-backend user with the runtime
        // toggle off (or on Intel) would otherwise pay that read for nothing. This
        // is behavior-identical to gating in `shouldUseLocal` — which still returns
        // false in exactly these cases — we just avoid resolving the path first.
        guard s.cotypingInProcessRuntime, Self.isAppleSilicon else { dropLocalEngine(); return nil }
        // Failure cooldown: the engine was already dropped (weights freed) in
        // handleLocalFailure, so just route to HTTP until the retry instant.
        if let retryLocalAt, now() < retryLocalAt { return nil }
        guard let url = resolvedModelURL(s),
              Self.shouldUseLocal(settings: s, modelURL: url, isAppleSilicon: Self.isAppleSilicon)
        else { dropLocalEngine(); return nil }
        if local == nil || localModelPath != url.path {
            local = makeLocal(url.path)
            localModelPath = url.path
            didLogLocalFailure = false
        }
        return local
    }

    private func takeLocalEngine() -> CotypingCompleting? {
        guard let engine = local else { return nil }
        local = nil
        localModelPath = nil
        return engine
    }

    /// Drops the cached in-process engine and frees its loaded model when the
    /// selector routes away from local (flag toggled off, Intel, or the model
    /// stops resolving). Self-limiting: a no-op once already dropped, so it's
    /// safe to call on every ineligible `localIfEligible()` pass. Setting
    /// `local = nil` alone is NOT enough — the runtime actor's deinit is async
    /// and may not run promptly, so we explicitly unload. When the flag flips
    /// back on and the model resolves, `localIfEligible()` rebuilds a fresh
    /// engine via `makeLocal` (cold reload on the next generate).
    private func dropLocalEngine() {
        guard let engine = takeLocalEngine() else { return }
        Task { await engine.unload() }
    }

    func prewarm() async {
        guard let engine = localIfEligible() else { return }
        try? await engine.prewarm()
    }

    func prewarm(for request: CotypingRequest) async {
        guard let engine = localIfEligible() else { return }
        try? await engine.prewarm(for: request)
    }

    func unload() async {
        guard let engine = takeLocalEngine() else { return }
        await engine.unload()
    }

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        guard let engine = localIfEligible() else { return try await http.generate(request) }
        do {
            let result = try await engine.generate(request)
            noteLocalSuccess()
            return result
        } catch let error as LlamaRuntimeError {
            handleLocalFailure(error)
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
            noteLocalSuccess()
            return result
        } catch let error as LlamaRuntimeError {
            handleLocalFailure(error)
            return try await http.generateStreaming(request, onPartial: onPartial)
        }
    }

    private func noteLocalSuccess() {
        didLogLocalFailure = false
        retryLocalAt = nil
    }

    /// In-process→HTTP fallback. The HTTP path runs the same GGUF in its own
    /// `llama-server` process, so keeping the failed local engine loaded would
    /// leave TWO ~6.66 GB copies of the weights resident. Instead: free the
    /// local model immediately and route to HTTP for `localRetryCooldown`, then
    /// rebuild and retry local (a cold reload, but at most once per cooldown —
    /// never per keystroke). Logged once per failure episode (spec §13).
    private func handleLocalFailure(_ error: LlamaRuntimeError) {
        if !didLogLocalFailure {
            didLogLocalFailure = true
            NSLog("""
            Cotyping: in-process runtime failed (\(error)); freeing the local model and using \
            the HTTP fallback for \(Int(Self.localRetryCooldown))s before retrying.
            """)
        }
        retryLocalAt = now().addingTimeInterval(Self.localRetryCooldown)
        dropLocalEngine()
    }
}
