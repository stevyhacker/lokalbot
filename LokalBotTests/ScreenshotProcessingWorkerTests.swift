import CoreGraphics
import CryptoKit
import XCTest
@testable import LokalBot

@MainActor
final class ScreenshotProcessingWorkerTests: XCTestCase {
    func testRetentionScheduleRunsDailyAndRespondsToPrivacyChanges() {
        var schedule = ScreenshotRetentionSchedule()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertTrue(schedule.shouldPrune(at: start))
        XCTAssertFalse(schedule.shouldPrune(at: start.addingTimeInterval(86_399)))
        XCTAssertTrue(schedule.shouldPrune(at: start.addingTimeInterval(86_400)))

        // A shorter retention window is an explicit privacy action, so it can
        // bypass the daily bound. A clock rollback must also not suspend
        // cleanup until wall time catches up with the old timestamp.
        XCTAssertTrue(schedule.shouldPrune(
            at: start.addingTimeInterval(86_460),
            force: true
        ))
        XCTAssertTrue(schedule.shouldPrune(at: start))

        XCTAssertTrue(ScreenshotRetentionSchedule.requiresImmediatePrune(
            previousDays: 14,
            currentDays: 7
        ))
        XCTAssertFalse(ScreenshotRetentionSchedule.requiresImmediatePrune(
            previousDays: 7,
            currentDays: 7
        ))
        XCTAssertFalse(ScreenshotRetentionSchedule.requiresImmediatePrune(
            previousDays: 7,
            currentDays: 14
        ))
    }

    func testRetentionMaintenanceUsesInjectedClockAndPreservesSavedMoments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotRetentionTests-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = StorageManager(rootURL: root)
        let store = ActivityStore(databaseURL: root.appendingPathComponent("activity.sqlite"))
        let sampler = ActivitySampler(store: store, notificationCenter: NotificationCenter())
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        var configuration = AppSettings()
        configuration.retentionDays = 1
        configuration.keepOCRTextForever = false
        let service = ScreenshotService(
            store: store,
            storage: storage,
            sampler: sampler,
            now: { clock },
            settings: { configuration }
        )

        let expired = clock.addingTimeInterval(-2 * 86_400)
        let ordinaryURL = root.appendingPathComponent("ordinary.heic.enc")
        let savedURL = root.appendingPathComponent("saved.heic.enc")
        try Data("ordinary pixels".utf8).write(to: ordinaryURL)
        try Data("saved pixels".utf8).write(to: savedURL)
        let ordinaryID = try store.insertScreenshot(
            ts: expired,
            path: ordinaryURL.path,
            app: "Notes",
            ocr: "ordinary private text"
        )
        let savedID = try store.insertScreenshot(
            ts: expired,
            path: savedURL.path,
            app: "Notes",
            ocr: "saved private text"
        )
        try store.saveMoment(snapshotID: savedID, note: "Keep this")

        XCTAssertTrue(service.runRetentionMaintenanceIfNeeded())
        XCTAssertFalse(FileManager.default.fileExists(atPath: ordinaryURL.path))
        XCTAssertNil(store.ocrText(snapshotID: ordinaryID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertEqual(store.ocrText(snapshotID: savedID), "saved private text")

        let delayedURL = root.appendingPathComponent("delayed.heic.enc")
        try Data("delayed pixels".utf8).write(to: delayedURL)
        let delayedID = try store.insertScreenshot(
            ts: expired,
            path: delayedURL.path,
            app: "Mail",
            ocr: "delete on next daily pass"
        )

        clock.addTimeInterval(86_399)
        XCTAssertFalse(service.runRetentionMaintenanceIfNeeded())
        XCTAssertTrue(FileManager.default.fileExists(atPath: delayedURL.path))
        XCTAssertEqual(store.ocrText(snapshotID: delayedID), "delete on next daily pass")

        clock.addTimeInterval(1)
        XCTAssertTrue(service.runRetentionMaintenanceIfNeeded())
        XCTAssertFalse(FileManager.default.fileExists(atPath: delayedURL.path))
        XCTAssertNil(store.ocrText(snapshotID: delayedID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertEqual(store.ocrText(snapshotID: savedID), "saved private text")
    }

    func testAutomaticDedupSkipsWorkButManualCaptureStillStoresEncryptedImage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotProcessingWorkerTests-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let image = try XCTUnwrap(Self.onePixelImage())
        let rawHEIC = Data("deterministic-heic-payload".utf8)
        let deterministicHash = Data(repeating: 0x17, count: 32)
        let key = SymmetricKey(data: Data(repeating: 0x2A, count: 32))
        let worker = ScreenshotProcessingWorker(dependencies: ScreenshotProcessingDependencies(
            contentHash: { _ in deterministicHash },
            heicData: { _ in rawHEIC },
            recognizeText: { _ in "Quarterly report revenue grew" },
            write: { data, url in
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }))

        let firstURL = root.appendingPathComponent("first.heic.enc")
        let first = try await worker.process(ScreenshotProcessingRequest(
            image: image, trigger: .appSwitch, key: key, fileURL: firstURL))
        guard case .stored(let hash, let ocrText) = first else {
            return XCTFail("The first automatic capture should be stored")
        }
        XCTAssertEqual(hash, deterministicHash)
        XCTAssertEqual(ocrText, "Quarterly report revenue grew")
        XCTAssertEqual(try Self.decrypt(firstURL, key: key), rawHEIC)

        let duplicateURL = root.appendingPathComponent("duplicate.heic.enc")
        let duplicate = try await worker.process(ScreenshotProcessingRequest(
            image: image, trigger: .windowChange, key: key, fileURL: duplicateURL))
        guard case .unchanged = duplicate else {
            return XCTFail("An unchanged automatic capture should be skipped")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicateURL.path))

        let manualURL = root.appendingPathComponent("manual.heic.enc")
        let manual = try await worker.process(ScreenshotProcessingRequest(
            image: image, trigger: .manual, key: key, fileURL: manualURL))
        guard case .stored(_, let manualOCR) = manual else {
            return XCTFail("A manual capture should bypass automatic dedup")
        }
        XCTAssertEqual(manualOCR, "Quarterly report revenue grew")
        XCTAssertEqual(try Self.decrypt(manualURL, key: key), rawHEIC)
    }

    func testDiscardedPersistenceAllowsIdenticalAutomaticCaptureToRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotProcessingWorkerTests-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try XCTUnwrap(Self.onePixelImage())
        let contentHash = Data(repeating: 0x44, count: 32)
        let key = SymmetricKey(data: Data(repeating: 0x55, count: 32))
        let worker = ScreenshotProcessingWorker(dependencies: ScreenshotProcessingDependencies(
            contentHash: { _ in contentHash },
            heicData: { _ in Data("image".utf8) },
            recognizeText: { _ in "retry me" },
            write: { data, url in
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }))

        let first = try await worker.process(.init(
            image: image, trigger: .interval, key: key,
            fileURL: root.appendingPathComponent("first.heic.enc")))
        guard case .stored(let storedHash, _) = first else {
            return XCTFail("The initial capture should store")
        }

        // ScreenshotService calls this after its SQLite transaction fails and
        // removes the encrypted file. The same screen must be allowed to retry.
        await worker.discardStored(contentHash: storedHash)
        let retry = try await worker.process(.init(
            image: image, trigger: .interval, key: key,
            fileURL: root.appendingPathComponent("retry.heic.enc")))

        guard case .stored = retry else {
            return XCTFail("A rolled-back capture must not poison dedup state")
        }
    }

    private static func onePixelImage() -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()
    }

    private static func decrypt(_ url: URL, key: SymmetricKey) throws -> Data {
        let encrypted = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: encrypted)
        return try AES.GCM.open(box, using: key)
    }
}
