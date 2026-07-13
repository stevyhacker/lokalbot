import XCTest
@testable import LokalBot

@MainActor
final class ProcessingPipelineModelPreparationTests: XCTestCase {
    func testFirstBuiltInSummaryPreparesMissingSelectedModel() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let storage = StorageManager(rootURL: root)
        var settings = AppSettings()
        settings.summarizerBackend = .builtIn
        settings.builtInModelID = ModelCatalog.compactFallbackID
        var preparationCount = 0
        let pipeline = ProcessingPipeline(
            storage: storage,
            settings: { settings },
            builtInModelPreparer: { entry, storage in
                preparationCount += 1
                let url = storage.rootURL.appendingPathComponent("models/\(entry.fileName)")
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("GGUF".utf8).write(to: url)
                return url
            })

        _ = try await pipeline.makeTextEngine(settings)
        _ = try await pipeline.makeTextEngine(settings)

        XCTAssertEqual(preparationCount, 1,
                       "first use downloads once; later summaries reuse the validated model")
        let entry = try XCTUnwrap(ModelCatalog.entry(id: settings.builtInModelID))
        XCTAssertNotNil(ModelCatalog.localURL(for: entry, storage: storage))
    }
}
