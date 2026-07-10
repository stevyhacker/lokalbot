import XCTest
@testable import LokalBot

final class AsyncSingleFlightTests: XCTestCase {
    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    private enum ExpectedFailure: Error { case failed }

    func testOverlappingCallersShareOneOperation() async throws {
        let flight = AsyncSingleFlight()
        let counter = Counter()

        async let first: Void = flight.run {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(75))
        }
        async let second: Void = flight.run {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(75))
        }
        async let third: Void = flight.run {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(75))
        }

        _ = try await (first, second, third)
        let sharedCount = await counter.value
        XCTAssertEqual(sharedCount, 1)
    }

    func testFailureDoesNotPoisonNextAttempt() async throws {
        let flight = AsyncSingleFlight()
        do {
            try await flight.run { throw ExpectedFailure.failed }
            XCTFail("Expected first attempt to fail")
        } catch ExpectedFailure.failed {
            // Expected.
        }

        let counter = Counter()
        try await flight.run { await counter.increment() }
        let retryCount = await counter.value
        XCTAssertEqual(retryCount, 1)
    }
}
