import CoreGraphics
import CryptoKit
import XCTest
@testable import LokalBot

@MainActor
final class ScreenshotProcessingWorkerTests: XCTestCase {
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
