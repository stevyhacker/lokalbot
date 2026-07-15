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
        XCTAssertEqual(hit.snapshotID, id)
        XCTAssertEqual(hit.id, id)
        XCTAssertEqual(hit.windowTitle, "Quarterly report — Google Docs")
        XCTAssertEqual(store.screenshot(id: id)?.id, id)
        XCTAssertEqual(store.ocrText(snapshotID: id), "Q3 revenue grew 14 percent")

        // Window titles are indexed too: a query matching only the title hits.
        XCTAssertEqual(store.searchOCR("quarterly").count, 1)
    }

    func testTextOnlyContextPersistsSanitizedProvenanceWithoutPretendingPixelsExist() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let capturedAt = Date()
        let meetingID = UUID().uuidString

        let id = try store.insertScreenshot(
            ts: capturedAt,
            path: "",
            app: "Safari",
            windowTitle: "Project brief",
            trigger: "typing_pause",
            textSource: "accessibility_redacted",
            ocr: "Visible project context [REDACTED]",
            sourceURL: "https://example.com/project",
            documentName: "Brief.md",
            meetingID: meetingID,
            privacyRedactions: 1)

        XCTAssertTrue(store.screenshots(on: capturedAt).isEmpty)
        let moment = try XCTUnwrap(
            store.screenshots(on: capturedAt, includingTextOnly: true).first)
        XCTAssertEqual(moment.id, id)
        XCTAssertFalse(moment.hasPixels)
        XCTAssertEqual(moment.sourceURL, "https://example.com/project")
        XCTAssertEqual(moment.documentName, "Brief.md")
        XCTAssertEqual(moment.meetingID, meetingID)
        XCTAssertEqual(moment.privacyRedactionCount, 1)
        XCTAssertEqual(store.ocrText(snapshotID: id), "Visible project context [REDACTED]")

        let reader = SQLiteScreenMemoryReader(databaseURL: url)
        let detail = try XCTUnwrap(reader.screenshotDetail(snapshotID: id))
        XCTAssertFalse(detail.hasEncryptedPixels)
        XCTAssertEqual(detail.sourceURL, "https://example.com/project")
        XCTAssertEqual(detail.documentName, "Brief.md")
        XCTAssertEqual(detail.meetingID, meetingID)
        XCTAssertEqual(detail.privacyRedactionCount, 1)
    }

    func testScreenshotAndOCRFiltersUseHalfOpenDateRangeAndExactApp() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let safariID = try store.insertScreenshot(
            ts: base, path: "/tmp/safari.heic.enc", app: "Safari",
            ocr: "shared launch checklist")
        _ = try store.insertScreenshot(
            ts: base.addingTimeInterval(60), path: "/tmp/xcode.heic.enc", app: "Xcode",
            ocr: "shared compile checklist")
        _ = try store.insertScreenshot(
            ts: base.addingTimeInterval(120), path: "/tmp/later.heic.enc", app: "Safari",
            ocr: "shared later checklist")
        let interval = DateInterval(start: base, end: base.addingTimeInterval(120))

        XCTAssertEqual(
            store.screenshots(in: interval, app: "sAfArI").map(\.id),
            [safariID])
        XCTAssertEqual(
            store.searchOCR(
                "shared", filter: ScreenSearchFilter(interval: interval, app: "SAFARI"))
                .map(\.snapshotID),
            [safariID])
    }

    func testSavedMomentsPersistNotesAndBookmarkState() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let snapshotID = try store.insertScreenshot(
            ts: Date(), path: "/tmp/moment.heic.enc", app: "Notes",
            windowTitle: "Project plan", trigger: "manual", ocr: "launch plan")

        try store.saveMoment(snapshotID: snapshotID, note: "Decision source")
        let createdAt = try XCTUnwrap(store.savedMoments().first?.createdAt)
        XCTAssertTrue(store.screenshot(id: snapshotID)?.isBookmarked == true)
        XCTAssertEqual(store.screenshots(bookmarkedOnly: true).map(\.id), [snapshotID])

        try store.saveMoment(snapshotID: snapshotID, note: "Updated note")
        let saved = try XCTUnwrap(store.savedMoments().first)
        XCTAssertEqual(saved.snapshotID, snapshotID)
        XCTAssertEqual(saved.note, "Updated note")
        XCTAssertEqual(saved.createdAt, createdAt)

        // A second store proves bookmark state is durable rather than cached.
        let reopened = ActivityStore(databaseURL: url)
        XCTAssertEqual(reopened.savedMoments().first?.note, "Updated note")
        try reopened.removeSavedMoment(snapshotID: snapshotID)
        XCTAssertTrue(reopened.savedMoments().isEmpty)
        XCTAssertFalse(reopened.screenshot(id: snapshotID)?.isBookmarked ?? true)
    }

    func testPerceptualHashesPersistAndNearDuplicatesShareAGroup() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let firstHash: UInt64 = 0x00FF_00FF_00FF_00FF
        let nearHash = firstHash ^ 0b101
        let farHash = ~firstHash
        let firstID = try store.insertScreenshot(
            ts: base, path: "/tmp/one.heic.enc", app: "Safari", ocr: "one",
            perceptualHash: firstHash)
        let nearID = try store.insertScreenshot(
            ts: base.addingTimeInterval(1), path: "/tmp/two.heic.enc", app: "Safari",
            ocr: "two", perceptualHash: nearHash)
        let farID = try store.insertScreenshot(
            ts: base.addingTimeInterval(2), path: "/tmp/three.heic.enc", app: "Safari",
            ocr: "three", perceptualHash: farHash)

        let first = try XCTUnwrap(store.screenshot(id: firstID))
        let near = try XCTUnwrap(store.screenshot(id: nearID))
        let far = try XCTUnwrap(store.screenshot(id: farID))
        XCTAssertEqual(first.perceptualHash, firstHash)
        XCTAssertEqual(near.perceptualHash, nearHash)
        XCTAssertEqual(first.similarityGroupID, firstID)
        XCTAssertEqual(near.similarityGroupID, firstID)
        XCTAssertEqual(far.similarityGroupID, farID)
    }

    func testPerceptualGroupingDoesNotDriftAwayFromItsRepresentative() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let representative: UInt64 = 0
        let nearRepresentative = representative ^ 0b11_1111
        let nearPreviousButFarFromRepresentative = nearRepresentative ^ (0b11_1111 << 6)

        let firstID = try store.insertScreenshot(
            ts: base, path: "/tmp/drift-one.heic.enc", app: "Safari", ocr: "one",
            perceptualHash: representative)
        let secondID = try store.insertScreenshot(
            ts: base.addingTimeInterval(1), path: "/tmp/drift-two.heic.enc", app: "Safari",
            ocr: "two", perceptualHash: nearRepresentative)
        let thirdID = try store.insertScreenshot(
            ts: base.addingTimeInterval(2), path: "/tmp/drift-three.heic.enc", app: "Safari",
            ocr: "three", perceptualHash: nearPreviousButFarFromRepresentative)

        XCTAssertEqual(store.screenshot(id: firstID)?.similarityGroupID, firstID)
        XCTAssertEqual(store.screenshot(id: secondID)?.similarityGroupID, firstID)
        XCTAssertEqual(store.screenshot(id: thirdID)?.similarityGroupID, thirdID)
    }

    func testDeleteScreenshotRemovesOCRBookmarkAndSemanticVector() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let snapshotID = try store.insertScreenshot(
            ts: Date(), path: "/tmp/delete.heic.enc", app: "Safari",
            ocr: "delete this source")
        try store.saveMoment(snapshotID: snapshotID)
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        try database.execute("""
            CREATE TABLE screen_embeddings (
                snapshot_id INTEGER PRIMARY KEY, ts REAL NOT NULL,
                app TEXT NOT NULL, text TEXT NOT NULL, vec BLOB NOT NULL,
                model_id TEXT NOT NULL DEFAULT '');
            """)
        try database.runChecked("""
            INSERT INTO screen_embeddings (snapshot_id, ts, app, text, vec, model_id)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            """, bind: [snapshotID, Date().timeIntervalSince1970, "Safari", "delete", Data([0]), "test"])

        try store.deleteScreenshot(id: snapshotID)

        XCTAssertNil(store.screenshot(id: snapshotID))
        XCTAssertNil(store.ocrText(snapshotID: snapshotID))
        XCTAssertTrue(store.savedMoments().isEmpty)
        XCTAssertFalse(try database.hasRowChecked(
            "SELECT 1 FROM screen_embeddings WHERE snapshot_id = ?1", bind: [snapshotID]))
    }

    func testReciprocalRankFusionIsStableAndRewardsAgreement() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let keyword = [
            ActivityStore.OCRHit(
                snapshotID: 1, ts: now, app: "Safari", snippet: "keyword one"),
            ActivityStore.OCRHit(
                snapshotID: 2, ts: now, app: "Xcode", snippet: "keyword two"),
        ]
        let semantic = [
            EmbeddingIndex.ScreenHit(
                snapshotID: 2, ts: now, app: "Xcode", text: "semantic two", score: 0.9),
            EmbeddingIndex.ScreenHit(
                snapshotID: 3, ts: now, app: "Notes", text: "semantic three", score: 0.8),
        ]

        let ranked = ScreenSearchRanker.fuse(
            keyword: keyword, semantic: semantic, limit: 3)

        XCTAssertEqual(ranked.map(\.snapshotID), [2, 1, 3])
        XCTAssertEqual(ranked.first?.keywordRank, 2)
        XCTAssertEqual(ranked.first?.semanticRank, 1)
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)
    }

    func testSemanticScreenRankingUsesCosineAndDeterministicTieBreaks() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let vectorData: ([Float]) -> Data = { values in
            values.withUnsafeBufferPointer { buffer in
                Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
            }
        }
        let candidates = [
            EmbeddingIndex.ScreenCandidate(
                snapshotID: 3, ts: now, app: "Notes", text: "weak",
                vector: vectorData([0.2, 0.8])),
            EmbeddingIndex.ScreenCandidate(
                snapshotID: 2, ts: now, app: "Xcode", text: "tie",
                vector: vectorData([0.8, 0.2])),
            EmbeddingIndex.ScreenCandidate(
                snapshotID: 1, ts: now, app: "Safari", text: "tie",
                vector: vectorData([0.8, 0.2])),
        ]

        let ranked = EmbeddingIndex.rankScreen(
            candidates, against: [1, 0], limit: 2)

        XCTAssertEqual(ranked.map(\.snapshotID), [1, 2])
        XCTAssertEqual(ranked.map(\.score), [0.8, 0.8])
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

    func testLegacyOCRMigrationUsesTimestampInsteadOfDivergedFTSRowID() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            let legacy = try XCTUnwrap(SQLiteDatabase(url: url))
            try legacy.execute("""
                CREATE TABLE screenshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL, path TEXT NOT NULL, app TEXT NOT NULL);
                CREATE VIRTUAL TABLE ocr_fts USING fts5(
                    text, ts UNINDEXED, app UNINDEXED,
                    tokenize='unicode61 remove_diacritics 2');
                """)
            try legacy.runChecked(
                "INSERT INTO screenshots (ts, path, app) VALUES (?1, ?2, ?3)",
                bind: [base.timeIntervalSince1970, "/tmp/no-ocr.heic.enc", "Notes"])
            try legacy.runChecked(
                "INSERT INTO screenshots (ts, path, app) VALUES (?1, ?2, ?3)",
                bind: [base.addingTimeInterval(10).timeIntervalSince1970,
                       "/tmp/with-ocr.heic.enc", "Notes"])
            // Empty OCR was never inserted in the legacy FTS table, so this
            // row's FTS rowid is 1 while its real screenshot id is 2.
            try legacy.runChecked(
                "INSERT INTO ocr_fts (text, ts, app) VALUES (?1, ?2, ?3)",
                bind: ["linked to the second frame",
                       base.addingTimeInterval(10).timeIntervalSince1970, "Notes"])
        }

        let store = ActivityStore(databaseURL: url)
        let hit = try XCTUnwrap(store.searchOCR("second").first)
        XCTAssertEqual(hit.snapshotID, 2)
        XCTAssertEqual(store.screenshot(id: hit.snapshotID)?.path, "/tmp/with-ocr.heic.enc")
    }

    func testExistingV2OCRMigrationRepairsZeroSnapshotID() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            let legacy = try XCTUnwrap(SQLiteDatabase(url: url))
            try legacy.execute("""
                CREATE TABLE screenshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL, path TEXT NOT NULL, app TEXT NOT NULL,
                    window_title TEXT NOT NULL DEFAULT '',
                    capture_trigger TEXT NOT NULL DEFAULT 'interval');
                CREATE VIRTUAL TABLE ocr_fts USING fts5(
                    text, window_title, ts UNINDEXED, app UNINDEXED,
                    text_source UNINDEXED, snapshot_id UNINDEXED,
                    tokenize='unicode61 remove_diacritics 2');
                """)
            try legacy.runChecked(
                "INSERT INTO screenshots (ts, path, app) VALUES (?1, ?2, ?3)",
                bind: [capturedAt.timeIntervalSince1970, "/tmp/v2.heic.enc", "Xcode"])
            try legacy.runChecked("""
                INSERT INTO ocr_fts (
                    text, window_title, ts, app, text_source, snapshot_id
                ) VALUES (?1, ?2, ?3, ?4, 'ocr', 0)
                """, bind: ["repair this orphan", "Editor",
                              capturedAt.timeIntervalSince1970, "xcode"])
        }

        let store = ActivityStore(databaseURL: url)
        let hit = try XCTUnwrap(store.searchOCR("orphan").first)
        XCTAssertEqual(hit.snapshotID, 1)
        XCTAssertEqual(store.ocrText(snapshotID: 1), "repair this orphan")
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
        XCTAssertTrue(ScreenshotService.shouldCaptureDuringMeetingRecording(
            trigger: .typingPause,
            recordingActive: true,
            visualContextEnabled: true))
    }

    func testAutomaticScreenCaptureSkipsTheLokalBotProcessButManualCaptureDoesNot() {
        let ownProcessID: pid_t = 42
        let automaticTriggers: [ScreenCaptureTrigger] = [
            .appSwitch, .windowChange, .click, .typingPause,
            .scrollSettled, .clipboardChange, .interval,
        ]

        for trigger in automaticTriggers {
            XCTAssertTrue(ScreenshotService.shouldSkipAutomaticSelfCapture(
                trigger: trigger,
                frontmostProcessID: ownProcessID,
                ownProcessID: ownProcessID))
        }
        XCTAssertFalse(ScreenshotService.shouldSkipAutomaticSelfCapture(
            trigger: .manual,
            frontmostProcessID: ownProcessID,
            ownProcessID: ownProcessID))
        XCTAssertFalse(ScreenshotService.shouldSkipAutomaticSelfCapture(
            trigger: .click,
            frontmostProcessID: 99,
            ownProcessID: ownProcessID))
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
            ScreenshotCaptureLayout.Window(
                id: 23, processID: 93, appName: "Safari", title: "Private Browsing — Start Page",
                frame: CGRect(x: 1_020, y: 20, width: 360, height: 320)),
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
        XCTAssertEqual(selection.excludedWindowIDs, Set<CGWindowID>([20, 21, 23]))

        let optedIn = try XCTUnwrap(ScreenshotCaptureLayout.selection(
            displays: displays,
            windows: windows,
            frontmostProcessID: 42,
            focusedWindowTitle: "focused report",
            excludedApps: ["1password", "SIGNAL"],
            excludePrivateWindows: false,
            mainDisplayID: 1))
        XCTAssertEqual(optedIn.excludedWindowIDs, Set<CGWindowID>([20, 21]))
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

    func testRetentionPreservesSavedMomentPixelsOCRAndEmbeddingUntilUnsaved() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let old = Date(timeIntervalSinceNow: -3 * 86_400)
        let cutoff = Date(timeIntervalSinceNow: -86_400)
        let savedID = try store.insertScreenshot(
            ts: old, path: "/tmp/saved-moment.heic.enc", app: "Notes",
            ocr: "saved launch decision")
        let ordinaryID = try store.insertScreenshot(
            ts: old, path: "/tmp/ordinary.heic.enc", app: "Safari",
            ocr: "ordinary expired context")
        try store.saveMoment(snapshotID: savedID, note: "Keep this")

        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        try database.execute("""
            CREATE TABLE screen_embeddings (
                snapshot_id INTEGER PRIMARY KEY, ts REAL NOT NULL,
                app TEXT NOT NULL, text TEXT NOT NULL, vec BLOB NOT NULL,
                model_id TEXT NOT NULL DEFAULT '');
            """)
        for (id, text) in [(savedID, "saved"), (ordinaryID, "ordinary")] {
            try database.runChecked("""
                INSERT INTO screen_embeddings (snapshot_id, ts, app, text, vec, model_id)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                """, bind: [id, old.timeIntervalSince1970, "Test", text, Data([0]), "test"])
        }

        XCTAssertEqual(
            Set(store.screenshotPaths(olderThan: cutoff)),
            Set(["/tmp/ordinary.heic.enc"]))
        XCTAssertTrue(store.clearOCRText(olderThan: cutoff))
        XCTAssertEqual(store.ocrText(snapshotID: savedID), "saved launch decision")
        XCTAssertNil(store.ocrText(snapshotID: ordinaryID))
        XCTAssertTrue(try database.hasRowChecked(
            "SELECT 1 FROM screen_embeddings WHERE snapshot_id = ?1", bind: [savedID]))
        XCTAssertFalse(try database.hasRowChecked(
            "SELECT 1 FROM screen_embeddings WHERE snapshot_id = ?1", bind: [ordinaryID]))

        try store.removeSavedMoment(snapshotID: savedID)
        XCTAssertEqual(
            Set(store.screenshotPaths(olderThan: cutoff)),
            Set(["/tmp/saved-moment.heic.enc", "/tmp/ordinary.heic.enc"]))
        XCTAssertTrue(store.clearOCRText(olderThan: cutoff))
        XCTAssertNil(store.ocrText(snapshotID: savedID))
        XCTAssertFalse(try database.hasRowChecked(
            "SELECT 1 FROM screen_embeddings WHERE snapshot_id = ?1", bind: [savedID]))
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
