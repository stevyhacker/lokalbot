import AppKit
import XCTest
@testable import LokalBot

// MARK: - Focus poll backoff

final class CotypingFocusPollBackoffTests: XCTestCase {
    private func idledBackoff(captures count: Int) -> CotypingFocusPollBackoff {
        var backoff = CotypingFocusPollBackoff()
        for _ in 0..<count {
            backoff.recordCapture(didChange: false)
        }
        return backoff
    }

    func testFocusTrackerDefaultCadenceAvoidsAggressiveIdleAXPolling() {
        XCTAssertEqual(CotypingFocusTracker.defaultIntervalMs, 200)
    }

    func testRecentActivityStaysAtFullCadence() {
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 0), 1)
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 4), 1)
    }

    func testStrideGrowsAsIdlePersists() {
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 5), 3)
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 11), 3)
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 12), 6)
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 29), 6)
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 30), 10)
    }

    func testStrideIsMonotonicNonDecreasing() {
        var previous = 0
        for count in 0...120 {
            let stride = CotypingFocusPollBackoff.captureStride(idleCaptureCount: count)
            XCTAssertGreaterThanOrEqual(stride, previous, "stride decreased at idleCaptureCount=\(count)")
            previous = stride
        }
    }

    func testChangeAfterIdleResetsToFullCadence() {
        var backoff = idledBackoff(captures: 400)
        XCTAssertEqual(backoff.idleCaptureCount, CotypingFocusPollBackoff.idleCaptureCountCap)
        XCTAssertGreaterThan(backoff.captureStride, 1)

        backoff.recordCapture(didChange: true)

        XCTAssertEqual(backoff.idleCaptureCount, 0)
        XCTAssertEqual(backoff.captureStride, 1)
    }

    func testExplicitRefreshResetReturnsToFullCadence() {
        var backoff = idledBackoff(captures: 30)
        XCTAssertEqual(backoff.captureStride, 10)

        backoff.reset()

        XCTAssertEqual(backoff.idleCaptureCount, 0)
        XCTAssertEqual(backoff.captureStride, 1)
    }

    func testMillisecondsSinceCaptureIsNilBeforeFirstCapture() {
        XCTAssertNil(CotypingFocusTracker.millisecondsSinceCapture(
            lastCaptureUptimeNanoseconds: nil,
            nowUptimeNanoseconds: 1_000_000))
    }

    func testMillisecondsSinceCaptureUsesCompletedCaptureTime() {
        XCTAssertEqual(CotypingFocusTracker.millisecondsSinceCapture(
            lastCaptureUptimeNanoseconds: 10_000_000,
            nowUptimeNanoseconds: 42_000_000), 32)
    }

    func testShouldRefreshCaptureWhenAgeUnknownOrOlderThanWindow() {
        XCTAssertTrue(CotypingFocusTracker.shouldRefreshCapture(
            lastCaptureUptimeNanoseconds: nil,
            nowUptimeNanoseconds: 42_000_000,
            maxAgeMilliseconds: 30))
        XCTAssertTrue(CotypingFocusTracker.shouldRefreshCapture(
            lastCaptureUptimeNanoseconds: 10_000_000,
            nowUptimeNanoseconds: 41_000_000,
            maxAgeMilliseconds: 30))
    }

    func testShouldReuseCaptureWithinFreshnessWindow() {
        XCTAssertFalse(CotypingFocusTracker.shouldRefreshCapture(
            lastCaptureUptimeNanoseconds: 10_000_000,
            nowUptimeNanoseconds: 40_000_000,
            maxAgeMilliseconds: 30))
        XCTAssertFalse(CotypingFocusTracker.shouldRefreshCapture(
            lastCaptureUptimeNanoseconds: 10_000_000,
            nowUptimeNanoseconds: 25_000_000,
            maxAgeMilliseconds: 30))
    }
}
