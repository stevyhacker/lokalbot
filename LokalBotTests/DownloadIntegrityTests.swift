import XCTest
@testable import LokalBot

final class DownloadIntegrityTests: XCTestCase {
    func testVerificationRejectsWrongDigestAndMarksValidFile() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("asset.bin")
        try Data("abc".utf8).write(to: file)
        let valid = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

        let acceptsWrongDigest = await DownloadIntegrity.verifiedExisting(
            at: file, expectedBytes: 3, expectedSHA256: String(repeating: "0", count: 64))
        XCTAssertFalse(acceptsWrongDigest)
        try await DownloadIntegrity.verifyDownloaded(
            at: file, expectedBytes: 3, expectedSHA256: valid)
        let validAfterMarking = await DownloadIntegrity.verifiedExisting(
            at: file, expectedBytes: 3, expectedSHA256: valid)
        XCTAssertTrue(validAfterMarking)
    }

    func testVerificationRejectsTruncatedFileEvenWithMarker() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("asset.bin")
        try Data("abc".utf8).write(to: file)
        let valid = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try await DownloadIntegrity.verifyDownloaded(
            at: file, expectedBytes: 3, expectedSHA256: valid)
        try Data("a".utf8).write(to: file)

        let acceptsTruncatedFile = await DownloadIntegrity.verifiedExisting(
            at: file, expectedBytes: 3, expectedSHA256: valid)
        XCTAssertFalse(acceptsTruncatedFile)
    }
}
