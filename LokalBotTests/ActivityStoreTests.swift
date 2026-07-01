import XCTest
@testable import LokalBot

@MainActor
final class ActivityStoreTests: XCTestCase {
    func testDayIntervalUsesCalendarDayAcrossSpringDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Podgorica"))

        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 12)))
        let interval = ActivityStore.dayInterval(containing: day, calendar: calendar)

        XCTAssertEqual(interval.duration, 23 * 60 * 60)
    }

    func testDayIntervalUsesCalendarDayAcrossFallDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Podgorica"))

        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12)))
        let interval = ActivityStore.dayInterval(containing: day, calendar: calendar)

        XCTAssertEqual(interval.duration, 25 * 60 * 60)
    }

    func testClearOCRTextRemovesOnlyRowsOlderThanCutoff() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)

        let old = Date(timeIntervalSinceNow: -3 * 86_400)
        store.insertScreenshot(ts: old, path: "/tmp/old.heic.enc", app: "Safari",
                               ocr: "ancient invoice number")
        store.insertScreenshot(ts: Date(), path: "/tmp/new.heic.enc", app: "Xcode",
                               ocr: "fresh build log")

        store.clearOCRText(olderThan: Date(timeIntervalSinceNow: -86_400))

        XCTAssertTrue(store.searchOCR("invoice").isEmpty)
        XCTAssertEqual(store.searchOCR("fresh").count, 1)
        // Pixel bookkeeping untouched: text pruning is independent of paths.
        XCTAssertEqual(store.screenshotPaths(olderThan: Date()).count, 2)
    }
}
