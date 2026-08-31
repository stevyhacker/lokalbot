import XCTest
@testable import LokalBot

final class StorageManagerTests: XCTestCase {
    func testDeleteMeetingRemovesDurableFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageManagerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let meeting = try storage.createMeetingFolder(title: "Delete me", appName: "Tests")
        let folder = meeting.folderURL(in: storage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        try storage.deleteMeeting(meeting)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testDeleteMeetingSurfacesFilesystemFailure() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageManagerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let missing = Meeting(
            id: UUID(), title: "Already gone", appName: "Tests",
            startedAt: Date(), endedAt: Date(), relativePath: "meetings/missing")

        XCTAssertThrowsError(try storage.deleteMeeting(missing))
    }

    func testLoadSurfacesUnavailableRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageManagerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)

        XCTAssertThrowsError(try StorageManager(rootURL: root).loadMeetingLibrary())
    }

    func testUnavailableRootRecoversOnSameInstanceAfterBlockerIsRemoved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageManagerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)
        let storage = StorageManager(rootURL: root)

        XCTAssertThrowsError(try storage.loadMeetingLibrary())
        try FileManager.default.removeItem(at: root)

        let load = try storage.loadMeetingLibrary()
        XCTAssertTrue(load.meetings.isEmpty)
        XCTAssertTrue(load.issues.isEmpty)

        let meeting = try storage.createMeetingFolder(title: "Recovered", appName: "Tests")
        let metadata = meeting.folderURL(in: storage).appendingPathComponent("meta.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
    }

    func testLoadKeepsValidMeetingsAndReportsCorruptMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageManagerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let valid = try storage.createMeetingFolder(title: "Valid", appName: "Tests")
        let corruptFolder = root.appendingPathComponent("meetings/2026/08/30-corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptFolder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corruptFolder.appendingPathComponent("meta.json"))

        let load = try storage.loadMeetingLibrary()

        XCTAssertEqual(load.meetings.map(\.id), [valid.id])
        XCTAssertEqual(load.issues.count, 1)
        XCTAssertTrue(load.issues[0].path.hasSuffix("meta.json"))
    }
}
