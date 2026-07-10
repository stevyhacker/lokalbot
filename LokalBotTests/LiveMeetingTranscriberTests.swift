import AVFoundation
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

    // MARK: - Audio preparation worker

    func testWorkerSkipsSnapshotWhenFreshAudioIsBelowMinimum() async throws {
        let source = root.appendingPathComponent(AudioPreviewTee.micFileName)
        let liveWriter = try writeCAF(
            samples: [Float](repeating: 0, count: Int(6 * 16_000)),
            to: source)
        let worker = LiveMeetingAudioPreparationWorker(storageRoot: root)

        let result = try await worker.prepareNextChunk(
            source: source,
            processedFrames: Int64(3 * 16_000))

        XCTAssertEqual(result, .noWork)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchDirectory.path),
                       "the metadata preflight should return before copying the growing CAF")
        XCTAssertGreaterThan(liveWriter.length, Int64(3 * 16_000),
                             "keep the production-like CAF writer open across the preflight")
    }

    func testWorkerAdvancesQuietAudioAndCleansSnapshot() async throws {
        let sampleRate = 16_000.0
        let samples = [Float](repeating: 0, count: Int(6 * sampleRate))
        let source = root.appendingPathComponent(AudioPreviewTee.micFileName)
        try writeCAF(samples: samples, to: source, sampleRate: sampleRate)
        let worker = LiveMeetingAudioPreparationWorker(storageRoot: root)
        let previousCursor = Int64(sampleRate)

        let result = try await worker.prepareNextChunk(
            source: source,
            processedFrames: previousCursor)

        guard case .advance(let processedFrames) = result else {
            return XCTFail("quiet audio should advance without producing an ASR window")
        }
        XCTAssertGreaterThan(processedFrames, previousCursor)
        XCTAssertLessThanOrEqual(processedFrames, Int64(samples.count))
        XCTAssertEqual(try scratchContents(), [],
                       "quiet chunks advance the cursor without leaking a snapshot or ASR window")
    }

    func testWorkerProducesSpeechWindowAndOwnsItsCleanup() async throws {
        let sampleRate = 16_000.0
        var samples = [Float](repeating: 0, count: Int(6 * sampleRate))
        addBurst(to: &samples, at: 1.0, duration: 0.4, sampleRate: sampleRate)
        addBurst(to: &samples, at: 3.0, duration: 0.4, sampleRate: sampleRate)
        let source = root.appendingPathComponent(AudioPreviewTee.micFileName)
        try writeCAF(samples: samples, to: source, sampleRate: sampleRate)
        let worker = LiveMeetingAudioPreparationWorker(storageRoot: root)

        let result = try await worker.prepareNextChunk(source: source, processedFrames: 0)

        guard case .ready(let prepared) = result else {
            return XCTFail("speech-like audio should produce an ASR window")
        }
        XCTAssertEqual(prepared.startTime, 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(prepared.processedFrames, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.url.path))
        let contents = try scratchContents()
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(
            contents.first?.resolvingSymlinksInPath(),
            prepared.url.resolvingSymlinksInPath())

        let reader = try AVAudioFile(forReading: prepared.url)
        XCTAssertEqual(reader.length, prepared.processedFrames)

        await worker.removePreparedChunk(at: prepared.url)
        XCTAssertEqual(try scratchContents(), [])
    }

    private var scratchDirectory: URL {
        root.appendingPathComponent(
            LiveMeetingTranscriber.scratchDirectoryName,
            isDirectory: true)
    }

    private func scratchContents() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: scratchDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: scratchDirectory,
            includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func addBurst(
        to samples: inout [Float],
        at startTime: TimeInterval,
        duration: TimeInterval,
        sampleRate: Double
    ) {
        let start = Int(startTime * sampleRate)
        let count = Int(duration * sampleRate)
        for offset in 0..<count {
            samples[start + offset] = 0.1 * Float(sin(
                2 * Double.pi * 400 * Double(offset) / sampleRate))
        }
    }

    @discardableResult
    private func writeCAF(
        samples: [Float],
        to url: URL,
        sampleRate: Double = 16_000
    ) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        samples.withUnsafeBufferPointer { pointer in
            channel.update(from: pointer.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
        return file
    }
}
