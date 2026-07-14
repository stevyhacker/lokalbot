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
}
