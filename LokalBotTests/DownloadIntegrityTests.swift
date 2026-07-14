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

@MainActor
final class ModelDownloadManagerCancellationTests: XCTestCase {
    func testLegacyCatalogModelIsHashedAndMarkedBeforeReuse() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-model-\(UUID().uuidString)", isDirectory: true)
        let storage = StorageManager(rootURL: root)
        let models = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let data = Data("GGUFlegacy-model".utf8)
        let model = models.appendingPathComponent("legacy.gguf")
        try data.write(to: model)
        let digest = try SHA256Verifier.hexDigest(of: model)
        let entry = ModelCatalog.Entry(
            id: "legacy", displayName: "Legacy", fileName: model.lastPathComponent,
            url: "https://example.com/legacy.gguf", sha256: digest,
            sizeBytes: Int64(data.count), sizeGB: Double(data.count) / 1_000_000_000,
            blurb: "", disablesThinking: false)

        let resolved = await ModelDownloadManager().verifiedExistingURL(entry, storage: storage)

        XCTAssertEqual(resolved, model)
        XCTAssertEqual(
            try String(contentsOf: model.appendingPathExtension("sha256"), encoding: .utf8),
            digest)
    }

    func testMismatchedLegacyCatalogModelIsRemoved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-model-\(UUID().uuidString)", isDirectory: true)
        let storage = StorageManager(rootURL: root)
        let models = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = models.appendingPathComponent("corrupt.gguf")
        try Data("GGUFbad!".utf8).write(to: model)
        let expectedFile = root.appendingPathComponent("expected.gguf")
        try Data("GGUFgood".utf8).write(to: expectedFile)
        let expectedDigest = try SHA256Verifier.hexDigest(of: expectedFile)
        let entry = ModelCatalog.Entry(
            id: "corrupt", displayName: "Corrupt", fileName: model.lastPathComponent,
            url: "https://example.com/corrupt.gguf", sha256: expectedDigest,
            sizeBytes: 8, sizeGB: 0.000_000_008,
            blurb: "", disablesThinking: false)

        let resolved = await ModelDownloadManager().verifiedExistingURL(entry, storage: storage)

        XCTAssertNil(resolved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path))
    }

    func testCancellationDuringSHA256VerificationRemovesOnlyCompletedStagedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-cancel-\(UUID().uuidString)", isDirectory: true)
        let storage = StorageManager(rootURL: root)
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/model.gguf"))
        let staged = root.appendingPathComponent("completed-whole-file.tmp")
        let stashDirectory = root.appendingPathComponent("models/.partial", isDirectory: true)
        let resumable = ParallelRangeDownloader.stashPartialURL(
            for: sourceURL, in: stashDirectory)
        let resumeManifest = stashDirectory.appendingPathComponent(
            "LokalBot-resume-\(ParallelRangeDownloader.stashName(for: sourceURL)).json")
        let gate = SHA256VerificationGate()
        let expectedDigest = String(repeating: "a", count: 64)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = ModelDownloadManager(
            stagedDownloader: { _, _, passedStashDirectory, _ in
                XCTAssertEqual(passedStashDirectory, stashDirectory)
                try FileManager.default.createDirectory(
                    at: stashDirectory, withIntermediateDirectories: true)
                try Data("whole file".utf8).write(to: staged)
                try Data("resumable bytes".utf8).write(to: resumable)
                try Data("resume manifest".utf8).write(to: resumeManifest)
                return staged
            },
            sha256Digest: { _ in
                await gate.suspendUntilReleased()
                return expectedDigest
            })

        manager.download(
            url: sourceURL.absoluteString,
            fileName: "model.gguf",
            id: "cancel-during-verification",
            expectedSHA256: expectedDigest,
            storage: storage)
        await gate.waitUntilSuspended()
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))

        manager.cancel(id: "cancel-during-verification")
        await gate.release()
        for _ in 0..<100 where FileManager.default.fileExists(atPath: staged.path) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resumable.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resumeManifest.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("models/model.gguf").path))
    }
}

private actor SHA256VerificationGate {
    private var suspended = false
    private var suspensionWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspendUntilReleased() async {
        suspended = true
        suspensionWaiter?.resume()
        suspensionWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { suspensionWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
