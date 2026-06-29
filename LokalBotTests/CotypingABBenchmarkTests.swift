import XCTest
@testable import LokalBot

final class CotypingABBenchmarkTests: XCTestCase {
    private func summary(latency: Int, ttft: Int) -> CotypingBenchmarkSummary {
        CotypingBenchmarkSummary(results: [
            CotypingBenchmarkCaseResult(
                scenarioID: "s", name: "s", text: "hello", latencyMs: latency,
                firstVisibleLatencyMs: ttft, expectedTermHits: 0, expectedTermCount: 0,
                suppression: nil, error: nil, expectedVisibleSuggestion: true,
                allowedSuppression: false, latencyTargetMs: 2000),
        ])
    }

    func testComparisonComputesDeltas() {
        let comparison = CotypingABComparison(
            local: summary(latency: 300, ttft: 120),
            http: summary(latency: 1100, ttft: 600))
        XCTAssertEqual(comparison.p95DeltaMs, 800)    // http p95 - local p95
        XCTAssertEqual(comparison.ttftDeltaMs, 480)   // http ttft - local ttft (local is faster)
    }

    func testComparisonHandlesMissingTTFT() {
        let comparison = CotypingABComparison(
            local: summary(latency: 300, ttft: 120),
            http: CotypingBenchmarkSummary(results: []))
        XCTAssertNil(comparison.p95DeltaMs)
        XCTAssertNil(comparison.ttftDeltaMs)
    }
}
