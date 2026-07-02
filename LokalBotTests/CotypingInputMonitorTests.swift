import AppKit
import XCTest
@testable import LokalBot

// MARK: - Input monitor

final class CotypingInputMonitorTests: XCTestCase {
    func testAcceptTapTeardownDelayMatchesCoTabbyFinalAcceptGuard() {
        XCTAssertEqual(CotypingInputMonitor.acceptTapTeardownDelaySeconds, 0.05, accuracy: 0.0001)
    }

    func testSyntheticSuppressionAccumulatesAcrossRapidBursts() {
        let controller = CotypingInputSuppressionController()
        let now = Date()

        controller.registerSyntheticInsertion(expectedKeyDownCount: 3, now: now)
        XCTAssertTrue(controller.consumeIfNeeded(now: now))
        controller.registerSyntheticInsertion(expectedKeyDownCount: 2, now: now)

        XCTAssertTrue(controller.consumeIfNeeded(now: now))
        XCTAssertTrue(controller.consumeIfNeeded(now: now))
        XCTAssertTrue(controller.consumeIfNeeded(now: now))
        XCTAssertTrue(controller.consumeIfNeeded(now: now))
        XCTAssertFalse(controller.consumeIfNeeded(now: now))
    }

    func testSyntheticSuppressionDropsStaleTokens() {
        let controller = CotypingInputSuppressionController()
        let now = Date()
        controller.registerSyntheticInsertion(expectedKeyDownCount: 5, now: now)

        XCTAssertFalse(controller.consumeIfNeeded(
            now: now.addingTimeInterval(
                CotypingInputSuppressionController.syntheticSuppressionWindowSeconds + 0.1)))

        controller.registerSyntheticInsertion(expectedKeyDownCount: 1, now: now)
        XCTAssertTrue(controller.consumeIfNeeded(now: now))
        XCTAssertFalse(controller.consumeIfNeeded(now: now))
    }
}
