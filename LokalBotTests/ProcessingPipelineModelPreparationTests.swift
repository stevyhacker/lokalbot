import XCTest
@testable import LokalBot

@MainActor
final class ProcessingPipelineModelPreparationTests: XCTestCase {
    private actor CancellationInsensitiveWork {
        private var started = false
        private var released = false
        private var completed = false
        private var cleanupReturned = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func run() async {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
            completed = true
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        func isCompleted() -> Bool { completed }
        func markCleanupReturned() { cleanupReturned = true }
        func didCleanupReturn() -> Bool { cleanupReturned }
    }

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

    func testCancelOutcomesWaitsForCancellationInsensitiveWork() async throws {
        let work = CancellationInsensitiveWork()
        let outcomesTask = Task { await work.run() }
        await work.waitUntilStarted()

        let cleanup = Task {
            await ProcessingPipeline.cancelAndWaitForOutcomes(outcomesTask)
            await work.markCleanupReturned()
        }
        try await Task.sleep(for: .milliseconds(50))
        let completedBeforeRelease = await work.isCompleted()
        XCTAssertFalse(completedBeforeRelease)
        let cleanupReturnedBeforeRelease = await work.didCleanupReturn()
        XCTAssertFalse(cleanupReturnedBeforeRelease)

        await work.release()
        await cleanup.value
        let completedAfterCleanup = await work.isCompleted()
        XCTAssertTrue(completedAfterCleanup)
        let cleanupReturnedAfterRelease = await work.didCleanupReturn()
        XCTAssertTrue(cleanupReturnedAfterRelease)
    }
}
