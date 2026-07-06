import XCTest
@testable import LokalBot

@MainActor
final class LiveMeetingTranscriberTests: XCTestCase {

    private var root: URL!
    private var transcriber: LiveMeetingTranscriber!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-transcriber-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        transcriber = LiveMeetingTranscriber(storageRoot: root) { AppSettings() }
    }

    override func tearDownWithError() throws {
        transcriber.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func testActivateWithoutPreparedRecordingIsANoOp() {
        transcriber.activate()
        XCTAssertFalse(transcriber.isRunning)
    }

    func testPrepareAloneCostsNothing() {
        transcriber.prepare(folder: root)
        XCTAssertFalse(transcriber.isRunning)
    }

    func testActivateStartsAfterPrepare() {
        transcriber.prepare(folder: root)
        transcriber.activate()
        XCTAssertTrue(transcriber.isRunning)
        transcriber.activate() // idempotent while running
        XCTAssertTrue(transcriber.isRunning)
    }

    func testOptInCarriesAcrossCalendarSplit() {
        transcriber.prepare(folder: root)
        transcriber.activate()
        transcriber.prepare(folder: root.appendingPathComponent("next-meeting"))
        XCTAssertTrue(transcriber.isRunning, "an activated transcriber resumes on the new folder")
    }

    func testStopEndsTheSessionAndDropsTheOptIn() {
        transcriber.prepare(folder: root)
        transcriber.activate()
        transcriber.stop()
        XCTAssertFalse(transcriber.isRunning)
        transcriber.activate()
        XCTAssertFalse(transcriber.isRunning, "no recording is prepared after stop")
    }

    func testSweepRemovesTheScratchDirectory() throws {
        let scratch = root.appendingPathComponent(LiveMeetingTranscriber.scratchDirectoryName,
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: scratch.appendingPathComponent("snap-x.caf"))
        LiveMeetingTranscriber.sweepOrphanedSnapshots(storageRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }
}
