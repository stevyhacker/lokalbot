import XCTest
import CoreGraphics
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

        let id = try store.insertScreenshot(
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

    func testSearchOCRRelaxedFallbackRescuesNaturalLanguage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        try store.insertScreenshot(ts: Date(), path: "/tmp/a.heic.enc", app: "Safari",
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
        try store.insertScreenshot(ts: Date(), path: "/tmp/new.heic.enc", app: "Xcode",
                                   windowTitle: "build log", trigger: "app_switch",
                                   ocr: "compile succeeded")
        XCTAssertEqual(store.searchOCR("compile").first?.windowTitle, "build log")
        XCTAssertEqual(store.screenshots(on: Date()).count, 2)
    }

    func testScreenshotAndOCRRowsRollbackTogetherWhenOCRInsertFails() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        try database.execute("DROP TABLE ocr_fts")

        XCTAssertThrowsError(try store.insertScreenshot(
            ts: Date(), path: "/tmp/rollback.heic.enc", app: "Safari",
            ocr: "this OCR insert must fail"))

        XCTAssertEqual(
            try database.firstDoubleChecked("SELECT COUNT(*) FROM screenshots"), 0,
            "The screenshot row must roll back when its searchable OCR pair fails")
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

    func testAutomaticScreenCapturesPauseDuringMeetingRecording() {
        XCTAssertFalse(ScreenshotService.shouldCaptureDuringMeetingRecording(
            trigger: .appSwitch,
            recordingActive: true))
        XCTAssertFalse(ScreenshotService.shouldCaptureDuringMeetingRecording(
            trigger: .windowChange,
            recordingActive: true))
        XCTAssertFalse(ScreenshotService.shouldCaptureDuringMeetingRecording(
            trigger: .interval,
            recordingActive: true))

        // Explicit user action still works while recording.
        XCTAssertTrue(ScreenshotService.shouldCaptureDuringMeetingRecording(
            trigger: .manual,
            recordingActive: true))
        XCTAssertTrue(ScreenshotService.shouldCaptureDuringMeetingRecording(
            trigger: .interval,
            recordingActive: false))
    }

    func testCaptureLayoutUsesFocusedWindowDisplayAndExcludesEveryPrivateWindowOnIt() throws {
        let displays = [
            ScreenshotCaptureLayout.Display(
                id: 1, frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)),
            ScreenshotCaptureLayout.Display(
                id: 2, frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800)),
        ]
        let windows = [
            // Same frontmost app on both displays; the title identifies the
            // actual focused window on display 2 rather than array order.
            ScreenshotCaptureLayout.Window(
                id: 10, processID: 42, appName: "Safari", title: "Other tab",
                frame: CGRect(x: 100, y: 100, width: 600, height: 500)),
            ScreenshotCaptureLayout.Window(
                id: 11, processID: 42, appName: "Safari", title: "Focused report",
                frame: CGRect(x: 1_100, y: 100, width: 700, height: 500)),
            ScreenshotCaptureLayout.Window(
                id: 20, processID: 90, appName: "1Password", title: "Secrets",
                frame: CGRect(x: 1_200, y: 200, width: 400, height: 400)),
            ScreenshotCaptureLayout.Window(
                id: 21, processID: 91, appName: "Signal", title: "Private chat",
                frame: CGRect(x: 1_650, y: 50, width: 300, height: 500)),
            // This excluded window is not on the selected display and does not
            // need to be handed to that display's ScreenCaptureKit filter.
            ScreenshotCaptureLayout.Window(
                id: 22, processID: 92, appName: "1Password", title: "Vault",
                frame: CGRect(x: 20, y: 20, width: 300, height: 300)),
        ]

        let selection = try XCTUnwrap(ScreenshotCaptureLayout.selection(
            displays: displays,
            windows: windows,
            frontmostProcessID: 42,
            focusedWindowTitle: "focused report",
            excludedApps: ["1password", "SIGNAL"],
            mainDisplayID: 1))

        XCTAssertEqual(selection.displayID, 2)
        XCTAssertEqual(selection.excludedWindowIDs, Set<CGWindowID>([20, 21]))
    }

    func testCaptureLayoutFallsBackToMainDisplayWithoutFocusedWindow() {
        let selection = ScreenshotCaptureLayout.selection(
            displays: [
                .init(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
                .init(id: 2, frame: CGRect(x: 800, y: 0, width: 800, height: 600)),
            ],
            windows: [],
            frontmostProcessID: 42,
            focusedWindowTitle: "",
            excludedApps: [],
            mainDisplayID: 2)

        XCTAssertEqual(selection?.displayID, 2)
    }

    func testCaptureFileNamesAndInFlightGateCannotCollide() {
        let root = URL(fileURLWithPath: "/tmp/screenshot-path-test", isDirectory: true)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.125)
        let first = ScreenshotService.captureFileURL(
            rootURL: root, timestamp: timestamp,
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let second = ScreenshotService.captureFileURL(
            rootURL: root, timestamp: timestamp,
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("1700000000125-"))

        var gate = ScreenshotCaptureGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        gate.end()
        XCTAssertTrue(gate.begin())
    }

    func testFocusedWindowTitleLookupRunsOffMainAndReturnsValue() async {
        let lookup = FocusedWindowTitleLookup { _ in
            Thread.isMainThread ? "main" : "background"
        }

        let result = await lookup.title(for: 42)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.title, "background")
    }

    func testFocusedWindowTitleLookupFailsClosedAtWholeOperationDeadline() async {
        let lookup = FocusedWindowTitleLookup(deadlineMilliseconds: 20) { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return "too late"
        }
        let started = ContinuousClock.now

        let result = await lookup.title(for: 42)

        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.title)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(150))
    }

    func testStalledWindowTitleLookupDoesNotQueueAnotherTarget() async {
        let blocker = DispatchSemaphore(value: 0)
        let probe = ActivityResolverInvocationProbe()
        let lookup = FocusedWindowTitleLookup(deadlineMilliseconds: 20) { _ in
            probe.recordInvocation()
            blocker.wait()
            return "late"
        }
        defer { blocker.signal() }

        let first = Task { await lookup.title(for: 42) }
        for _ in 0..<20 where probe.invocationCount == 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(probe.invocationCount, 1)
        let firstResult = await first.value
        XCTAssertTrue(firstResult.timedOut)

        let started = ContinuousClock.now
        let second = await lookup.title(for: 43)

        XCTAssertTrue(second.timedOut)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(20))
        XCTAssertEqual(probe.invocationCount, 1)
    }

    func testScreenshotWindowFocusValidationFailsClosedOnTimeoutOrChange() {
        XCTAssertTrue(ScreenshotWindowFocusValidation.matches(
            expectedTitle: "Résumé",
            current: .init(title: "resume", timedOut: false)))
        XCTAssertTrue(ScreenshotWindowFocusValidation.matches(
            expectedTitle: "",
            current: .init(title: nil, timedOut: false)))
        XCTAssertFalse(ScreenshotWindowFocusValidation.matches(
            expectedTitle: "Report",
            current: .timeout))
        XCTAssertFalse(ScreenshotWindowFocusValidation.matches(
            expectedTitle: "Report",
            current: .init(title: "Chat", timedOut: false)))
    }

    func testActivitySamplerRemovesTerminationObserverWhenStopped() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let sampler = ActivitySampler(
            store: ActivityStore(databaseURL: url),
            notificationCenter: NotificationCenter())

        XCTAssertFalse(sampler.hasTerminationObserver)
        sampler.start()
        XCTAssertTrue(sampler.hasTerminationObserver)
        sampler.stop()
        XCTAssertFalse(sampler.hasTerminationObserver)
    }

    func testClearOCRTextRemovesOnlyRowsOlderThanCutoff() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)

        let old = Date(timeIntervalSinceNow: -3 * 86_400)
        try store.insertScreenshot(ts: old, path: "/tmp/old.heic.enc", app: "Safari",
                                   ocr: "ancient invoice number")
        try store.insertScreenshot(ts: Date(), path: "/tmp/new.heic.enc", app: "Xcode",
                                   ocr: "fresh build log")

        store.clearOCRText(olderThan: Date(timeIntervalSinceNow: -86_400))

        XCTAssertTrue(store.searchOCR("invoice").isEmpty)
        XCTAssertEqual(store.searchOCR("fresh").count, 1)
        // Pixel bookkeeping untouched: text pruning is independent of paths.
        XCTAssertEqual(store.screenshotPaths(olderThan: Date()).count, 2)
    }
}

private final class ActivityResolverInvocationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func recordInvocation() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
