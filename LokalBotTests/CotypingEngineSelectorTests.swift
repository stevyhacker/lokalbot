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

    /// FIX 2: a thrown `LlamaRuntimeError.decodeFailed` from the local engine must
    /// reach the selector's `catch let error as LlamaRuntimeError` and fall back to
    /// HTTP. Enabled by the `CotypingCompleting` seam on `makeLocal` (a throwing
    /// fake can now be injected as the local engine).
    func testDecodeFailureFallsBackToHTTP() throws {
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

/// A local-engine fake that always throws a `LlamaRuntimeError`, used to prove
/// the selector's HTTP fallback fires on a decode failure (Fix 2).
@MainActor
private final class ThrowingLocalEngine: CotypingCompleting {
    let error: LlamaRuntimeError
    init(error: LlamaRuntimeError) { self.error = error }
    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        throw error
    }
}
