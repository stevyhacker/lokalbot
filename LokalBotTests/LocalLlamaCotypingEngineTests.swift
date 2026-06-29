import XCTest
@testable import LokalBot

@MainActor
final class LocalLlamaCotypingEngineTests: XCTestCase {
    private func bundledModelPath() throws -> String {
        let entry = ModelCatalog.entry(id: ModelCatalog.bundledID)!
        guard let url = ModelCatalog.localURL(for: entry, storage: StorageManager()) else {
            throw XCTSkip("Bundled model not present; skipping engine integration test.")
        }
        return url.path
    }

    private func makeRequest() -> CotypingRequest {
        let field = CotypingField(
            appName: "Mail", bundleID: "com.apple.mail", processID: 0, role: "AXTextArea",
            precedingText: "Hi Sarah,\nThanks for sending this over. I wanted to follow",
            trailingText: "", selectionLength: 0, caretRect: .zero, isSecure: false,
            caretIsExact: true, windowTitle: "Re: Q3", fieldPlaceholder: nil)
        return CotypingRequestBuilder.build(
            field: field, config: .standard,
            personalization: .none, generation: 1, learnedExamples: [])!
    }

    func testGenerateReturnsNormalizedResult() async throws {
        let path = try bundledModelPath()
        let engine = LocalLlamaCotypingEngine(runtime: LlamaCotypingRuntime(), modelPath: path)
        let result = try await engine.generate(makeRequest())
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testStreamingFiresPartials() async throws {
        let path = try bundledModelPath()
        let engine = LocalLlamaCotypingEngine(runtime: LlamaCotypingRuntime(), modelPath: path)
        var partials = 0
        _ = try await engine.generateStreaming(makeRequest()) { _ in partials += 1 }
        XCTAssertGreaterThan(partials, 0)
    }
}
