import AVFoundation
import XCTest
@testable import LokalBotV3

final class AudioFileInspectorTests: XCTestCase {
    func testRejectsHeaderOnlyAudioFile() throws {
        let url = temporaryURL(name: "empty.caf")
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: true,
                ])
            XCTAssertEqual(file.length, 0)
        }

        XCTAssertFalse(AudioFileInspector.isTranscribableAudio(at: url))
    }

    func testAcceptsAudioAboveMinimumDuration() throws {
        let url = temporaryURL(name: "speech.caf")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: 16_000,
                                                 channels: 1,
                                                 interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: true,
                ])
            try file.write(from: buffer)
            XCTAssertGreaterThan(file.length, 0)
        }

        XCTAssertTrue(AudioFileInspector.isTranscribableAudio(at: url))
    }

    private func temporaryURL(name: String) -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}
