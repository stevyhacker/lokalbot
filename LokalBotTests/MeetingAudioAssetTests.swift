import AVFoundation
import XCTest
@testable import LokalBotV3

final class MeetingAudioAssetTests: XCTestCase {
    func testPrepareUsesBothTracksWhenSystemAudioExists() throws {
        let folder = try temporaryFolder()
        try writeTone(to: folder.appendingPathComponent("mic.m4a"), frequency: 440, duration: 0.25)
        try writeTone(to: folder.appendingPathComponent("system.m4a"), frequency: 660, duration: 0.4)

        let prepared = try MeetingAudioAsset.prepare(folder: folder, hasSystemTrack: true)

        XCTAssertEqual(prepared.trackCount, 2)
        XCTAssertEqual(prepared.audioMix.inputParameters.count, 2)
        XCTAssertEqual(prepared.duration, 0.4, accuracy: 0.08)
    }

    func testExportMixedRecordingWritesReadableM4A() async throws {
        let folder = try temporaryFolder()
        try writeTone(to: folder.appendingPathComponent("mic.m4a"), frequency: 440, duration: 0.25)
        try writeTone(to: folder.appendingPathComponent("system.m4a"), frequency: 660, duration: 0.25)
        let output = folder.appendingPathComponent("export.m4a")

        try await MeetingAudioAsset.exportMixedRecording(folder: folder, hasSystemTrack: true, to: output)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let exported = try AVAudioFile(forReading: output)
        XCTAssertGreaterThan(exported.length, 0)
    }

    private func temporaryFolder() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        return folder
    }

    private func writeTone(to url: URL, frequency: Double, duration: TimeInterval) throws {
        let sampleRate = 16_000.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: sampleRate,
                                                 channels: 1,
                                                 interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount

        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frameCount) {
            samples[index] = Float(sin(2 * .pi * frequency * Double(index) / sampleRate) * 0.25)
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ])
        try file.write(from: buffer)
    }
}
