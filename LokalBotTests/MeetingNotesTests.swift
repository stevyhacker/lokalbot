import XCTest
@testable import LokalBot

final class MeetingNotesTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-notes-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testRoundTrip() throws {
        try MeetingNotes.write("- ship the beta\n- ping Ana", to: folder)
        XCTAssertEqual(try MeetingNotes.load(from: folder), "- ship the beta\n- ping Ana")
    }

    func testMissingFileLoadsNil() throws {
        XCTAssertNil(try MeetingNotes.load(from: folder))
    }

    func testBlankTextRemovesTheFile() throws {
        try MeetingNotes.write("something", to: folder)
        try MeetingNotes.write("   \n\t ", to: folder)
        XCTAssertNil(try MeetingNotes.load(from: folder))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(MeetingNotes.fileName).path))
    }

    func testPromptContextEmptyWithoutNotes() throws {
        XCTAssertEqual(try MeetingNotes.promptContext(in: folder), [])
    }

    func testPromptContextCarriesTheNotes() throws {
        try MeetingNotes.write("decision: go with plan B", to: folder)
        let context = try MeetingNotes.promptContext(in: folder)
        XCTAssertEqual(context.count, 1)
        XCTAssertTrue(context[0].contains("decision: go with plan B"))
        XCTAssertTrue(context[0].contains("Notes the user typed"))
    }

    func testWriteSurfacesFilesystemFailure() throws {
        let blockedFolder = folder.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedFolder)

        XCTAssertThrowsError(try MeetingNotes.write("do not lose this", to: blockedFolder))
    }

    func testLoadSurfacesUnreadableNotesPath() throws {
        let notesURL = folder.appendingPathComponent(MeetingNotes.fileName, isDirectory: true)
        try FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try MeetingNotes.load(from: folder))
    }
}
