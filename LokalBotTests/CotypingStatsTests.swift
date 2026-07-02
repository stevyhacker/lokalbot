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

    func testCodableRoundTrip() {
        var stats = CotypingStats()
        stats.recordGeneration(latencyMs: 120)
        stats.recordGeneration(latencyMs: 340)
        stats.recordAccept(charsAccepted: 9)
        stats.recordError()
        let data = try! JSONEncoder().encode(stats)
        let decoded = try! JSONDecoder().decode(CotypingStats.self, from: data)
        XCTAssertEqual(decoded, stats)
    }
}

final class CotypingStatsStoreTests: XCTestCase {
    @MainActor
    func testPersistAndReload() {
        let name = "cotyping-stats-test"
        UserDefaults().removePersistentDomain(forName: name)
        let suite = UserDefaults(suiteName: name)!

        let store = CotypingStatsStore(defaults: suite)
        XCTAssertEqual(store.stats, CotypingStats())

        store.recordGeneration(latencyMs: 120)
        store.recordAccept(charsAccepted: 7)
        store.recordError()

        // A fresh store loading the same suite sees the persisted values.
        let reloaded = CotypingStatsStore(defaults: suite)
        XCTAssertEqual(reloaded.stats.generations, 1)
        XCTAssertEqual(reloaded.stats.accepts, 1)
        XCTAssertEqual(reloaded.stats.charsAccepted, 7)
        XCTAssertEqual(reloaded.stats.errors, 1)

        reloaded.clear()
        XCTAssertEqual(CotypingStatsStore(defaults: suite).stats, CotypingStats())

        suite.removePersistentDomain(forName: name)
    }
}
