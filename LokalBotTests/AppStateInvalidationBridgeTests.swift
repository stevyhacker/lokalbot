import Combine
import XCTest
@testable import LokalBot

@MainActor
final class AppStateInvalidationBridgeTests: XCTestCase {
    func testSynchronousChildChangesCoalesceIntoOneEmission() async {
        let changes = PassthroughSubject<Void, Never>()
        var emissionCount = 0
        let emitted = expectation(description: "coalesced emission")
        let bridge = AppStateInvalidationBridge {
            emissionCount += 1
            emitted.fulfill()
        }
        bridge.observe(changes)

        changes.send()
        changes.send()
        changes.send()
        await fulfillment(of: [emitted], timeout: 1)
        await Task.yield()

        XCTAssertEqual(emissionCount, 1)
    }

    func testLaterChildChangeEmitsAgain() async {
        let changes = PassthroughSubject<Void, Never>()
        var emissionCount = 0
        let first = expectation(description: "first emission")
        let second = expectation(description: "second emission")
        let bridge = AppStateInvalidationBridge {
            emissionCount += 1
            if emissionCount == 1 { first.fulfill() }
            if emissionCount == 2 { second.fulfill() }
        }
        bridge.observe(changes)

        changes.send()
        await fulfillment(of: [first], timeout: 1)
        changes.send()
        await fulfillment(of: [second], timeout: 1)

        XCTAssertEqual(emissionCount, 2)
    }
}
