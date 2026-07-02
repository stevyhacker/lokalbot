import AppKit
import XCTest
@testable import LokalBot

final class CotypingDebounceTests: XCTestCase {
    func testCotypistParityFloorIsTwentyMilliseconds() {
        XCTAssertEqual(CotypingDebouncePolicy.minimumMilliseconds, 20)
        XCTAssertEqual(CotypingDebouncePolicy.milliseconds(lastLatencyMilliseconds: nil, configured: 20), 20)
    }

    func testConfiguredBelowFloorIsClamped() {
        XCTAssertEqual(CotypingDebouncePolicy.milliseconds(lastLatencyMilliseconds: nil, configured: 5), 20)
    }

    func testNoLatencyUsesConfigured() {
        XCTAssertEqual(CotypingDebouncePolicy.milliseconds(lastLatencyMilliseconds: nil, configured: 150), 150)
    }
    func testFastKeepsConfiguredFloor() {
        XCTAssertEqual(CotypingDebouncePolicy.milliseconds(lastLatencyMilliseconds: 120, configured: 150), 150)
    }
    func testSlowBacksOff() {
        XCTAssertEqual(CotypingDebouncePolicy.milliseconds(lastLatencyMilliseconds: 800, configured: 150), 400)
    }
    func testBackoffCapped() {
        XCTAssertEqual(CotypingDebouncePolicy.milliseconds(lastLatencyMilliseconds: 4000, configured: 150), 600)
    }
    func testHostPublishWaitConsumesDebounceWindow() {
        XCTAssertEqual(
            CotypingDebouncePolicy.milliseconds(
                lastLatencyMilliseconds: nil,
                configured: 150,
                consumedDelayMilliseconds: 40),
            110)
    }
    func testHostPublishWaitCanExhaustDebounceWindow() {
        XCTAssertEqual(
            CotypingDebouncePolicy.milliseconds(
                lastLatencyMilliseconds: 800,
                configured: 150,
                consumedDelayMilliseconds: 450),
            0)
    }
}
