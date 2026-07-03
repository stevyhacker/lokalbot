import XCTest
@testable import LokalBot

@MainActor
final class CotypingEngineSelectorTests: XCTestCase {
    private let modelURL = URL(fileURLWithPath: "/models/gemma.gguf")

    func testUsesLocalWhenFlagOnAppleSiliconAndModelResolves() {
        var s = AppSettings(); s.cotypingInProcessRuntime = true
        XCTAssertTrue(CotypingEngineSelector.shouldUseLocal(
            settings: s, modelURL: modelURL, isAppleSilicon: true))
    }

    func testFallsBackWhenFlagOff() {
        var s = AppSettings(); s.cotypingInProcessRuntime = false
        XCTAssertFalse(CotypingEngineSelector.shouldUseLocal(
            settings: s, modelURL: modelURL, isAppleSilicon: true))
    }

    func testFallsBackOnIntel() {
        var s = AppSettings(); s.cotypingInProcessRuntime = true
        XCTAssertFalse(CotypingEngineSelector.shouldUseLocal(
            settings: s, modelURL: modelURL, isAppleSilicon: false))
    }

    func testFallsBackWhenModelMissing() {
        var s = AppSettings(); s.cotypingInProcessRuntime = true
        XCTAssertFalse(CotypingEngineSelector.shouldUseLocal(
            settings: s, modelURL: nil, isAppleSilicon: true))
    }

    // MARK: - Route-away unload (Fix 1) + decode-failure fallback (Fix 2)

    /// FIX 1: when the runtime flag flips OFF the selector must drop its cached
    /// in-process engine (and unload its model); flipping it back ON rebuilds a
    /// fresh engine. We prove the cache is dropped by counting `makeLocal` calls
    /// through the injectable seam: build → drop → rebuild ⇒ exactly two builds.
    ///
    /// These selector paths only run on Apple Silicon (`isAppleSilicon`), so the
    /// test is skipped on Intel where `localIfEligible()` always returns nil.
    func testRouteAwayDropsCacheAndRebuildOnReenable() throws {
        try XCTSkipUnless(CotypingEngineSelector.isAppleSilicon,
                          "Selector routes to local only on Apple Silicon.")
        let env = try GGUFFixture()
        defer { env.tearDown() }

        var flagOn = true
        let http = RecordingHTTPEngine()
        let counter = BuildCounter()
        let selector = CotypingEngineSelector(
            http: http,
            makeLocal: { _ in counter.bump(); return RecordingHTTPEngine() },
            settings: {
                var s = env.settings
                s.cotypingInProcessRuntime = flagOn
                return s
            },
            storage: env.storage)

        // Flag ON + model resolves → first build, routes local (HTTP untouched).
        let r1 = makeMinimalRequestExpectingNoServer()
        _ = try? awaitGenerate(selector, r1)
        XCTAssertEqual(counter.value, 1, "flag ON should build the local engine once")

        // Flag OFF → ineligible branch calls dropLocalEngine(), routes to HTTP.
        flagOn = false
        let httpBefore = http.generateCalls
        _ = try? awaitGenerate(selector, r1)
        XCTAssertEqual(http.generateCalls, httpBefore + 1, "flag OFF should route to HTTP")
        XCTAssertEqual(counter.value, 1, "flag OFF must not build a new local engine")

        // Flag ON again → cache was dropped, so a FRESH engine is rebuilt.
        flagOn = true
        _ = try? awaitGenerate(selector, r1)
        XCTAssertEqual(counter.value, 2,
                       "re-enabling after route-away must rebuild a fresh local engine")
    }

    /// FIX 2 (selector half): a `LlamaRuntimeError` thrown by the local engine must
    /// reach the selector's `catch let error as LlamaRuntimeError` and route the
    /// completion to HTTP. This injects a `ThrowingLocalEngine` fake (enabled by the
    /// `CotypingCompleting` seam on `makeLocal`), so it proves the selector's
    /// fallback wiring — NOT that `LlamaCotypingRuntime.generate` actually throws on
    /// a failed `llama_decode`. That runtime half is locked by compilation (the
    /// `try await` propagation in `LlamaCotypingRuntimeTests`); a genuine
    /// `llama_decode == 0` fault (KV exhaustion / OOM) can't be provoked
    /// deterministically in a unit test.
    func testLocalRuntimeErrorRoutesToHTTPFallback() throws {
        try XCTSkipUnless(CotypingEngineSelector.isAppleSilicon,
                          "Selector routes to local only on Apple Silicon.")
        let env = try GGUFFixture()
        defer { env.tearDown() }

        let http = RecordingHTTPEngine()
        let selector = CotypingEngineSelector(
            http: http,
            makeLocal: { _ in ThrowingLocalEngine(error: .decodeFailed) },
            settings: { env.settings },
            storage: env.storage)

        let result = try awaitGenerate(selector, makeMinimalRequestExpectingNoServer())
        XCTAssertEqual(http.generateCalls, 1,
                       "a thrown LlamaRuntimeError must route the completion to HTTP")
        XCTAssertEqual(result.text, RecordingHTTPEngine.sentinel,
                       "the returned result must be the HTTP engine's output")
    }

    /// The HTTP fallback runs the SAME GGUF in its own llama-server process, so
    /// a failed in-process engine must not stay loaded beside it (two ~6.66 GB
    /// copies resident). A failure must (1) unload the local engine's weights,
    /// (2) route to HTTP without rebuilding local for `localRetryCooldown`, and
    /// (3) rebuild + retry local once the cooldown passes.
    func testLocalFailureFreesModelAndCoolsDownBeforeRetry() throws {
        try XCTSkipUnless(CotypingEngineSelector.isAppleSilicon,
                          "Selector routes to local only on Apple Silicon.")
        let env = try GGUFFixture()
        defer { env.tearDown() }

        var clock = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let http = RecordingHTTPEngine()
        var locals: [ThrowingLocalEngine] = []
        let selector = CotypingEngineSelector(
            http: http,
            makeLocal: { _ in
                let engine = ThrowingLocalEngine(error: .decodeFailed)
                locals.append(engine)
                return engine
            },
            settings: { env.settings },
            storage: env.storage,
            now: { clock })

        let request = makeMinimalRequestExpectingNoServer()

        // Failure → HTTP fallback + the failed engine's weights are freed.
        _ = try awaitGenerate(selector, request)
        XCTAssertEqual(locals.count, 1)
        XCTAssertEqual(http.generateCalls, 1, "the failed completion must land on HTTP")
        drainMainQueue()
        XCTAssertEqual(locals[0].unloadCalls, 1,
                       "a local failure must unload the in-process weights, not keep them resident")

        // Inside the cooldown: straight to HTTP, no local rebuild (no reload thrash).
        clock += CotypingEngineSelector.localRetryCooldown - 1
        _ = try awaitGenerate(selector, request)
        XCTAssertEqual(locals.count, 1, "no rebuild while the failure cooldown is active")
        XCTAssertEqual(http.generateCalls, 2)

        // Past the cooldown: rebuild a fresh local engine and retry it.
        clock += 2
        _ = try awaitGenerate(selector, request)
        XCTAssertEqual(locals.count, 2, "cooldown expiry must rebuild and retry the local engine")
        XCTAssertEqual(http.generateCalls, 3, "the retried engine failed again, so HTTP serves it")
    }

    func testExplicitUnloadAwaitsLocalEngineAndRebuilds() throws {
        try XCTSkipUnless(CotypingEngineSelector.isAppleSilicon,
                          "Selector routes to local only on Apple Silicon.")
        let env = try GGUFFixture()
        defer { env.tearDown() }

        let http = RecordingHTTPEngine()
        var locals: [RecordingLocalEngine] = []
        let selector = CotypingEngineSelector(
            http: http,
            makeLocal: { _ in
                let engine = RecordingLocalEngine()
                locals.append(engine)
                return engine
            },
            settings: { env.settings },
            storage: env.storage)

        let request = makeMinimalRequestExpectingNoServer()
        _ = try awaitGenerate(selector, request)
        XCTAssertEqual(locals.count, 1, "first eligible completion should build one local engine")

        awaitUnload(selector)
        XCTAssertEqual(locals[0].unloadCalls, 1, "explicit unload must await the local engine unload")

        _ = try awaitGenerate(selector, request)
        XCTAssertEqual(locals.count, 2, "next eligible completion should rebuild after explicit unload")
    }

    // MARK: - Helpers

    /// Builds a temp StorageManager rooted at a throwaway dir with a GGUF-magic
    /// file and a matching custom catalog entry, so `resolvedModelURL` resolves
    /// without a real 6.66 GB model. `looksLikeGGUF` only checks the first 4
    /// bytes are the ASCII magic "GGUF".
    private struct GGUFFixture {
        let storage: StorageManager
        let settings: AppSettings
        private let tempRoot: URL
        private let previousDefault: String?

        init() throws {
            tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("lokalbot-selector-\(UUID().uuidString)", isDirectory: true)
            let modelsDir = tempRoot.appendingPathComponent("models", isDirectory: true)
            try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

            let fileName = "selector-fixture.gguf"
            let modelFile = modelsDir.appendingPathComponent(fileName)
            try Data("GGUF".utf8).write(to: modelFile)   // magic-only stub; not loaded

            // Point StorageManager at the temp root via the UI-test override hook.
            previousDefault = UserDefaults.standard.string(forKey: UITestRuntime.storageRootKey)
            UserDefaults.standard.set(tempRoot.path, forKey: UITestRuntime.storageRootKey)
            storage = StorageManager()

            let custom = ModelCatalog.Entry(
                id: "selector-fixture", displayName: "Selector Fixture",
                fileName: fileName, url: "", sizeGB: 0, blurb: "", disablesThinking: false)
            var s = AppSettings()
            s.cotypingInProcessRuntime = true
            s.customBuiltInModels = [custom]
            s.cotypingBuiltInModelID = custom.id
            settings = s
        }

        func tearDown() {
            if let previousDefault {
                UserDefaults.standard.set(previousDefault, forKey: UITestRuntime.storageRootKey)
            } else {
                UserDefaults.standard.removeObject(forKey: UITestRuntime.storageRootKey)
            }
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    /// A request whose generation never reaches a real server: the fakes above
    /// short-circuit before any network/model call, so the prompt content is
    /// irrelevant — we only need a valid `CotypingRequest`.
    private func makeMinimalRequestExpectingNoServer() -> CotypingRequest {
        let field = CotypingField(
            appName: "Mail", bundleID: "com.apple.mail", processID: 0, role: "AXTextArea",
            precedingText: "Hi Sarah,\nThanks for sending this over. I wanted to follow",
            trailingText: "", selectionLength: 0, caretRect: .zero, isSecure: false,
            caretIsExact: true, windowTitle: "Re: Q3", fieldPlaceholder: nil)
        return CotypingRequestBuilder.build(
            field: field, config: .standard,
            personalization: .none, generation: 1, learnedExamples: [])!
    }

    private func awaitGenerate(
        _ selector: CotypingEngineSelector, _ request: CotypingRequest
    ) throws -> CotypingNormalizationResult {
        let exp = expectation(description: "generate")
        var captured: Result<CotypingNormalizationResult, Error>!
        Task { @MainActor in
            do { captured = .success(try await selector.generate(request)) }
            catch { captured = .failure(error) }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        return try captured.get()
    }

    /// `dropLocalEngine` fires `unload()` in an unstructured Task; pump the
    /// main actor a few times so that task has run before we assert on it.
    private func drainMainQueue(hops: Int = 5) {
        for _ in 0..<hops {
            let exp = expectation(description: "drain")
            Task { @MainActor in exp.fulfill() }
            wait(for: [exp], timeout: 5)
        }
    }

    private func awaitUnload(_ selector: CotypingEngineSelector) {
        let exp = expectation(description: "unload")
        Task { @MainActor in
            await selector.unload()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }
}

/// Thread-safe build counter for the `makeLocal` seam.
private final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Stands in for the HTTP `CotypingCompleting` and records that it was invoked,
/// returning a sentinel result so the caller can assert the fallback path ran.
@MainActor
private final class RecordingHTTPEngine: CotypingCompleting {
    static let sentinel = "HTTP-FALLBACK"
    private(set) var generateCalls = 0
    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        generateCalls += 1
        return CotypingNormalizationResult(text: Self.sentinel, suppression: nil)
    }
}

@MainActor
private final class RecordingLocalEngine: CotypingCompleting {
    private(set) var generateCalls = 0
    private(set) var unloadCalls = 0

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        generateCalls += 1
        return CotypingNormalizationResult(text: "LOCAL", suppression: nil)
    }

    func unload() async {
        unloadCalls += 1
    }
}

/// A local-engine fake that always throws a `LlamaRuntimeError`, used to prove
/// the selector's HTTP fallback fires on a decode failure (Fix 2). Records
/// unloads so tests can assert the failed engine's weights were freed.
@MainActor
private final class ThrowingLocalEngine: CotypingCompleting {
    let error: LlamaRuntimeError
    private(set) var unloadCalls = 0
    init(error: LlamaRuntimeError) { self.error = error }
    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        throw error
    }
    func unload() async { unloadCalls += 1 }
}
