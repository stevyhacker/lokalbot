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

    func testInsertScreenshotStoresTriggerTitleAndLinksOCRRow() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)

        let id = store.insertScreenshot(
            ts: Date(), path: "/tmp/a.heic.enc", app: "Safari",
            windowTitle: "Quarterly report — Google Docs", trigger: "window_change",
            ocr: "Q3 revenue grew 14 percent")
        XCTAssertGreaterThan(id, 0)

        let shot = try XCTUnwrap(store.screenshots(on: Date()).first)
        XCTAssertEqual(shot.app, "Safari")
        XCTAssertEqual(shot.windowTitle, "Quarterly report — Google Docs")
        XCTAssertEqual(shot.trigger, "window_change")

        let hit = try XCTUnwrap(store.searchOCR("revenue").first)
        XCTAssertEqual(hit.windowTitle, "Quarterly report — Google Docs")

        // Window titles are indexed too: a query matching only the title hits.
        XCTAssertEqual(store.searchOCR("quarterly").count, 1)
    }

    func testSearchOCRRelaxedFallbackRescuesNaturalLanguage() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        store.insertScreenshot(ts: Date(), path: "/tmp/a.heic.enc", app: "Safari",
                               ocr: "kubernetes deployment rollback steps")

        // Strict ANDs the stop words and misses…
        XCTAssertTrue(store.searchOCR("what were the rollback steps").isEmpty)
        // …the relaxed OR query rescues the content terms.
        XCTAssertFalse(store.searchOCR("what were the rollback steps",
                                       matchAll: false, dropStopWords: true).isEmpty)
    }

    func testMigratesLegacySchemaPreservingRows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        // Plant the pre-event-driven schema: screenshots without window_title /
        // capture_trigger, ocr_fts with only (text, ts, app).
        do {
            let legacy = try XCTUnwrap(SQLiteDatabase(url: url))
            legacy.exec("""
                CREATE TABLE screenshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL, path TEXT NOT NULL, app TEXT NOT NULL);
                CREATE VIRTUAL TABLE ocr_fts USING fts5(
                    text, ts UNINDEXED, app UNINDEXED,
                    tokenize='unicode61 remove_diacritics 2');
                """)
            legacy.run("INSERT INTO screenshots (ts, path, app) VALUES (?1, ?2, ?3)",
                       bind: [Date().timeIntervalSince1970, "/tmp/legacy.heic.enc", "Notes"])
            legacy.run("INSERT INTO ocr_fts (text, ts, app) VALUES (?1, ?2, ?3)",
                       bind: ["grocery list milk eggs", Date().timeIntervalSince1970, "Notes"])
        }

        let store = ActivityStore(databaseURL: url)

        // Legacy rows survive with default trigger/title, and stay searchable.
        let legacyShot = try XCTUnwrap(store.screenshots(on: Date()).first)
        XCTAssertEqual(legacyShot.app, "Notes")
        XCTAssertEqual(legacyShot.trigger, "interval")
        XCTAssertEqual(legacyShot.windowTitle, "")
        XCTAssertEqual(store.searchOCR("grocery").count, 1)

        // New-shape inserts work on the migrated tables.
        store.insertScreenshot(ts: Date(), path: "/tmp/new.heic.enc", app: "Xcode",
                               windowTitle: "build log", trigger: "app_switch",
                               ocr: "compile succeeded")
        XCTAssertEqual(store.searchOCR("compile").first?.windowTitle, "build log")
        XCTAssertEqual(store.screenshots(on: Date()).count, 2)
    }

    // MARK: - Capture policy

    func testCapturePolicyCooldownAndIdleFallback() {
        var policy = ScreenCapturePolicy(eventCooldown: 20)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // First ever check always captures.
        XCTAssertTrue(policy.shouldCapture(trigger: .appSwitch, idleInterval: 180, now: t0))
        policy.noteCheck(at: t0)

        // Event triggers inside the cooldown are dropped; after it, allowed.
        XCTAssertFalse(policy.shouldCapture(trigger: .appSwitch, idleInterval: 180,
                                            now: t0.addingTimeInterval(5)))
        XCTAssertFalse(policy.shouldCapture(trigger: .windowChange, idleInterval: 180,
                                            now: t0.addingTimeInterval(19)))
        XCTAssertTrue(policy.shouldCapture(trigger: .windowChange, idleInterval: 180,
                                           now: t0.addingTimeInterval(21)))

        // The interval trigger waits for the full idle window…
        XCTAssertFalse(policy.shouldCapture(trigger: .interval, idleInterval: 180,
                                            now: t0.addingTimeInterval(60)))
        XCTAssertTrue(policy.shouldCapture(trigger: .interval, idleInterval: 180,
                                           now: t0.addingTimeInterval(181)))

        // …and manual always fires.
        XCTAssertTrue(policy.shouldCapture(trigger: .manual, idleInterval: 180,
                                           now: t0.addingTimeInterval(1)))
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
