import XCTest
@testable import LokalBot

final class DailyMemoryExportSchedulerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }

    func testDoesNotRunBeforeConfiguredHour() throws {
        XCTAssertFalse(DailyMemoryExportScheduler.shouldRun(
            at: try date("2026-07-14T17:59:00Z"), hour: 18,
            lastSuccessfulDay: nil, calendar: calendar))
    }

    func testRunsAtOrAfterConfiguredHour() throws {
        XCTAssertTrue(DailyMemoryExportScheduler.shouldRun(
            at: try date("2026-07-14T18:00:00Z"), hour: 18,
            lastSuccessfulDay: nil, calendar: calendar))
        XCTAssertTrue(DailyMemoryExportScheduler.shouldRun(
            at: try date("2026-07-14T23:30:00Z"), hour: 18,
            lastSuccessfulDay: nil, calendar: calendar))
    }

    func testRunsOnlyOncePerLocalDay() throws {
        XCTAssertFalse(DailyMemoryExportScheduler.shouldRun(
            at: try date("2026-07-14T23:30:00Z"), hour: 18,
            lastSuccessfulDay: try date("2026-07-14T18:00:00Z"),
            calendar: calendar))
        XCTAssertTrue(DailyMemoryExportScheduler.shouldRun(
            at: try date("2026-07-15T18:00:00Z"), hour: 18,
            lastSuccessfulDay: try date("2026-07-14T18:00:00Z"),
            calendar: calendar))
    }

    @MainActor
    func testDisablingCancelsInFlightExportWorker() async throws {
        let current = try date("2026-07-14T18:00:00Z")
        let scheduler = DailyMemoryExportScheduler(calendar: calendar, now: { current })
        let started = expectation(description: "export worker started")
        let cancelled = expectation(description: "export worker cancelled")
        let unexpectedError = expectation(description: "cancellation was reported as an error")
        unexpectedError.isInverted = true

        scheduler.configure(.init(enabled: true, hour: 18, destinationID: "first")) { _ in
            started.fulfill()
            do {
                while true {
                    try await Task.sleep(for: .seconds(60))
                }
            } catch is CancellationError {
                cancelled.fulfill()
                throw CancellationError()
            }
        } onError: { _ in
            unexpectedError.fulfill()
        }

        await fulfillment(of: [started], timeout: 2)
        scheduler.configure(.init(enabled: false, hour: 18, destinationID: "")) { _ in
        } onError: { _ in
            unexpectedError.fulfill()
        }
        await fulfillment(of: [cancelled], timeout: 2)
        await fulfillment(of: [unexpectedError], timeout: 0.1)
        scheduler.stop()
    }
}
