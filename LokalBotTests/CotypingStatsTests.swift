import AppKit
import XCTest
@testable import LokalBot

// MARK: - Quality metrics

final class CotypingStatsTests: XCTestCase {
    func testDefaults() {
        let stats = CotypingStats()
        XCTAssertEqual(stats.generations, 0)
        XCTAssertEqual(stats.accepts, 0)
        XCTAssertEqual(stats.charsAccepted, 0)
        XCTAssertEqual(stats.latenciesMs, [])
        XCTAssertNil(stats.avgLatencyMs)
        XCTAssertNil(stats.p95LatencyMs)
        XCTAssertEqual(stats.acceptsPerGeneration, 0)
    }

    func testRecordGenerationAndAccept() {
        var stats = CotypingStats()
        stats.recordGeneration(latencyMs: 100)
        stats.recordGeneration(latencyMs: 200)
        stats.recordAccept(charsAccepted: 12)
        XCTAssertEqual(stats.generations, 2)
        XCTAssertEqual(stats.accepts, 1)
        XCTAssertEqual(stats.charsAccepted, 12)
        XCTAssertEqual(stats.acceptsPerGeneration, 0.5, accuracy: 0.001)
    }

    func testLatencyCap() {
        var stats = CotypingStats()
        for ms in 1...55 { stats.recordGeneration(latencyMs: ms) }
        XCTAssertEqual(stats.latenciesMs.count, CotypingStats.maxLatencies)  // 50
        XCTAssertEqual(stats.latenciesMs.first, 6)  // first five dropped
        XCTAssertEqual(stats.latenciesMs.last, 55)
    }

    func testDerivedLatencyStats() {
        var stats = CotypingStats()
        [100, 200, 300, 400, 500].forEach { stats.recordGeneration(latencyMs: $0) }
        XCTAssertEqual(stats.avgLatencyMs, 300)
        XCTAssertEqual(stats.medianLatencyMs, 300)
        XCTAssertEqual(stats.p95LatencyMs, 500)   // idx = round(4*0.95) = 4
        XCTAssertEqual(stats.maxLatencyMs, 500)
    }

    func testSingleSampleLatency() {
        var stats = CotypingStats()
        stats.recordGeneration(latencyMs: 150)
        XCTAssertEqual(stats.avgLatencyMs, 150)
        XCTAssertEqual(stats.medianLatencyMs, 150)
        XCTAssertEqual(stats.p95LatencyMs, 150)
        XCTAssertEqual(stats.maxLatencyMs, 150)
    }

    func testReset() {
        var stats = CotypingStats()
        stats.recordGeneration(latencyMs: 100)
        stats.recordError()
        stats.reset()
        XCTAssertEqual(stats, CotypingStats())
    }

    func testCodableRoundTrip() throws {
        var stats = CotypingStats()
        stats.recordGeneration(latencyMs: 120)
        stats.recordGeneration(latencyMs: 340)
        stats.recordAccept(charsAccepted: 9)
        stats.recordError()
        let data = try JSONEncoder().encode(stats)
        let decoded = try JSONDecoder().decode(CotypingStats.self, from: data)
        XCTAssertEqual(decoded, stats)
    }
}

final class CotypingStatsStoreTests: XCTestCase {
    @MainActor
    func testPersistAndReload() async {
        let name = "cotyping-stats-test"
        UserDefaults().removePersistentDomain(forName: name)
        let suite = UserDefaults(suiteName: name)!

        let store = CotypingStatsStore(defaults: suite)
        XCTAssertEqual(store.stats, CotypingStats())

        store.recordGeneration(latencyMs: 120)
        store.recordAccept(charsAccepted: 7)
        store.recordError()
        store.suggestionCompleted()
        await store.flushPersistence()

        // A fresh store loading the same suite sees the persisted values.
        let reloaded = CotypingStatsStore(defaults: suite)
        XCTAssertEqual(reloaded.stats.generations, 1)
        XCTAssertEqual(reloaded.stats.accepts, 1)
        XCTAssertEqual(reloaded.stats.charsAccepted, 7)
        XCTAssertEqual(reloaded.stats.errors, 1)

        reloaded.clear()
        await reloaded.flushPersistence()
        XCTAssertEqual(CotypingStatsStore(defaults: suite).stats, CotypingStats())

        suite.removePersistentDomain(forName: name)
    }

    @MainActor
    func testAcceptedChunksPersistOnceAtSuggestionCompletion() async {
        let persistence = RecordingCotypingStatsPersistence()
        let name = "cotyping-stats-batch-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let store = CotypingStatsStore(defaults: suite, persistence: persistence)

        store.recordAccept(charsAccepted: 4)
        store.recordAccept(charsAccepted: 6)
        store.recordAccept(charsAccepted: 2)
        await store.waitForPendingPersistence()
        let beforeCompletion = await persistence.recordedStats()
        XCTAssertTrue(beforeCompletion.isEmpty,
                      "accepted chunks must not each trigger a defaults write")

        store.suggestionCompleted()
        await store.waitForPendingPersistence()

        let snapshots = await persistence.recordedStats()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].accepts, 3)
        XCTAssertEqual(snapshots[0].charsAccepted, 12)
        suite.removePersistentDomain(forName: name)
    }

    @MainActor
    func testTerminationFlushPersistsDirtyAcceptedChunks() async {
        let persistence = RecordingCotypingStatsPersistence()
        let name = "cotyping-stats-flush-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let store = CotypingStatsStore(defaults: suite, persistence: persistence)
        store.recordAccept(charsAccepted: 9)

        await store.flushPersistence()

        let snapshots = await persistence.recordedStats()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].accepts, 1)
        XCTAssertEqual(snapshots[0].charsAccepted, 9)
        suite.removePersistentDomain(forName: name)
    }
}

private actor RecordingCotypingStatsPersistence: CotypingStatsPersisting {
    private var snapshots: [CotypingStats] = []
    private var removeCount = 0

    func persist(_ stats: CotypingStats) {
        snapshots.append(stats)
    }

    func remove() {
        removeCount += 1
    }

    func recordedStats() -> [CotypingStats] { snapshots }
}
