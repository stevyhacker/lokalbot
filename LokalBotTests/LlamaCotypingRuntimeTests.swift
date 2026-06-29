import XCTest
@testable import LokalBot

final class LlamaCotypingRuntimeTests: XCTestCase {

    /// Resolves the bundled tiny model from the app bundle's Resources, or skips.
    private func bundledModelPath() throws -> String {
        let entry = ModelCatalog.entry(id: ModelCatalog.bundledID)!
        let storage = StorageManager()
        guard let url = ModelCatalog.localURL(for: entry, storage: storage) else {
            throw XCTSkip("Bundled model \(entry.fileName) not present; skipping libllama integration test.")
        }
        return url.path
    }

    private let standardSpecs = LlamaSamplerSpec.specs(from: .standard)

    func testLoadsAndGeneratesDeterministically() async throws {
        let path = try bundledModelPath()
        let runtime = LlamaCotypingRuntime()
        try await runtime.loadIfNeeded(modelPath: path)
        let loaded = await runtime.isLoaded
        XCTAssertTrue(loaded)

        let prompt = await runtime.tokenize("The capital of France is", addBOS: true)
        XCTAssertFalse(prompt.isEmpty)

        let first = await runtime.generate(
            promptTokens: prompt, maxTokens: 8, samplerSpecs: standardSpecs) { _ in true }
        XCTAssertFalse(first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        // Same prompt + fixed seed (0x00C0FFEE in standardSpecs) → identical output.
        try await runtime.loadIfNeeded(modelPath: path) // no-op reload
        let second = await runtime.generate(
            promptTokens: prompt, maxTokens: 8, samplerSpecs: standardSpecs) { _ in true }
        XCTAssertEqual(first, second, "fixed seed must produce deterministic output")
    }

    func testKVReuseDecodesOnlySuffix() async throws {
        let path = try bundledModelPath()
        let runtime = LlamaCotypingRuntime()
        try await runtime.loadIfNeeded(modelPath: path)

        let base = await runtime.tokenize("Hi Sarah, thanks for sending this over. I wanted to follow", addBOS: true)
        _ = await runtime.generate(promptTokens: base, maxTokens: 2, samplerSpecs: standardSpecs) { _ in true }
        let firstPrefill = await runtime.lastPrefillTokenCount
        XCTAssertEqual(firstPrefill, base.count, "cold prompt prefills every token")

        // Extend the prompt: the shared prefix must be reused, only the suffix decoded.
        let extended = base + (await runtime.tokenize(" up tomorrow", addBOS: false))
        _ = await runtime.generate(promptTokens: extended, maxTokens: 2, samplerSpecs: standardSpecs) { _ in true }
        let secondPrefill = await runtime.lastPrefillTokenCount
        XCTAssertLessThan(secondPrefill, extended.count, "KV reuse must skip the shared prefix")
        XCTAssertEqual(secondPrefill, extended.count - base.count,
                       "only the appended suffix should be prefilled")
    }

    func testOnTokenReturningFalseStopsDecode() async throws {
        let path = try bundledModelPath()
        let runtime = LlamaCotypingRuntime()
        try await runtime.loadIfNeeded(modelPath: path)
        let prompt = await runtime.tokenize("Once upon a time", addBOS: true)
        let counter = TokenCounter()
        let out = await runtime.generate(
            promptTokens: prompt, maxTokens: 20, samplerSpecs: standardSpecs
        ) { _ in counter.increment() < 3 }   // stop after 3 tokens
        XCTAssertLessThanOrEqual(counter.value, 3)
        XCTAssertFalse(out.isEmpty)
    }
}

/// Thread-safe counter so the `@Sendable` onToken closure can tally tokens
/// without tripping Swift's concurrent-capture diagnostics.
private final class TokenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    /// Increments and returns the new count (so the first call returns 1).
    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
