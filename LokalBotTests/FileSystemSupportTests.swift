import XCTest
@testable import LokalBot

final class FileSystemSupportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSystemSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOptionalInspectionDistinguishesFilesDirectoriesAndMissingItems() throws {
        let file = root.appendingPathComponent("artifact.txt")
        let directory = root.appendingPathComponent("artifacts", isDirectory: true)
        let missing = root.appendingPathComponent("missing.txt")
        try Data("artifact".utf8).write(to: file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertTrue(try FileSystemSupport.itemExists(at: file))
        XCTAssertEqual(try FileSystemSupport.itemIsDirectory(at: file), false)
        XCTAssertEqual(try FileSystemSupport.itemIsDirectory(at: directory), true)
        XCTAssertFalse(try FileSystemSupport.itemExists(at: missing))
        XCTAssertNil(try FileSystemSupport.attributesIfPresent(at: missing))
    }

    func testRemoveIfPresentIsIdempotent() throws {
        let file = root.appendingPathComponent("artifact.txt")
        try Data("artifact".utf8).write(to: file)

        try FileSystemSupport.removeIfPresent(file)
        try FileSystemSupport.removeIfPresent(file)

        XCTAssertFalse(try FileSystemSupport.itemExists(at: file))
    }
}
