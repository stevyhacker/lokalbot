import XCTest
@testable import LokalBot

final class MeetingArtifactLoaderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingArtifactLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testMissingArtifactsAreNormal() {
        let snapshot = MeetingArtifactLoader.loadWorkspace(from: folder)

        XCTAssertNil(snapshot.summary)
        XCTAssertNil(snapshot.notes)
        XCTAssertNil(snapshot.transcript)
        XCTAssertTrue(snapshot.issues.isEmpty)
    }

    func testLoadsWorkspaceArtifacts() throws {
        try Data("# Summary".utf8).write(to: folder.appendingPathComponent("summary.md"))
        try MeetingNotes.write("Remember this", to: folder)
        let transcript = Transcript(
            segments: [.init(start: 0, end: 1, speaker: "me", text: "Hello")],
            engine: "test")
        try JSONEncoder().encode(transcript).write(to: folder.appendingPathComponent("transcript.json"))

        let snapshot = MeetingArtifactLoader.loadWorkspace(from: folder)

        XCTAssertEqual(snapshot.summary, "# Summary")
        XCTAssertEqual(snapshot.notes, "Remember this")
        XCTAssertEqual(snapshot.transcript?.segments.first?.text, "Hello")
        XCTAssertTrue(snapshot.issues.isEmpty)
    }

    func testCorruptArtifactIsReportedWithoutHidingValidArtifacts() throws {
        try Data("# Summary".utf8).write(to: folder.appendingPathComponent("summary.md"))
        try Data("not json".utf8).write(to: folder.appendingPathComponent("transcript.json"))

        let snapshot = MeetingArtifactLoader.loadWorkspace(from: folder)

        XCTAssertEqual(snapshot.summary, "# Summary")
        XCTAssertNil(snapshot.transcript)
        XCTAssertEqual(snapshot.issues.map(\.artifact), ["transcript"])
    }
}
