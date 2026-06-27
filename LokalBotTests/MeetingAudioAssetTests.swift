import AVFoundation
import XCTest
@testable import LokalBot

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

    func testPlaybackSourcesGainStaging() throws {
        let folder = try temporaryFolder()
        try writeTone(to: folder.appendingPathComponent("mic.m4a"), frequency: 440, duration: 0.1)
        try writeTone(to: folder.appendingPathComponent("system.m4a"), frequency: 660, duration: 0.1)

        // Both tracks: system kept dominant, mic attenuated to tame bleed.
        let both = MeetingAudioAsset.playbackSources(folder: folder, hasSystemTrack: true)
        XCTAssertEqual(both.map(\.url.lastPathComponent), ["system.m4a", "mic.m4a"])
        XCTAssertEqual(both.map(\.gain), [0.85, 0.55])

        // System present on disk but not flagged for this meeting: mic only, full gain.
        let micOnly = MeetingAudioAsset.playbackSources(folder: folder, hasSystemTrack: false)
        XCTAssertEqual(micOnly.map(\.url.lastPathComponent), ["mic.m4a"])
        XCTAssertEqual(micOnly.map(\.gain), [1.0])
    }

    func testPlaybackSourcesSystemOnlyAndEmpty() throws {
        let systemFolder = try temporaryFolder()
        try writeTone(to: systemFolder.appendingPathComponent("system.m4a"), frequency: 660, duration: 0.1)
        let systemOnly = MeetingAudioAsset.playbackSources(folder: systemFolder, hasSystemTrack: true)
        XCTAssertEqual(systemOnly.map(\.url.lastPathComponent), ["system.m4a"])
        XCTAssertEqual(systemOnly.map(\.gain), [1.0])

        XCTAssertTrue(MeetingAudioAsset.playbackSources(folder: try temporaryFolder(),
                                                        hasSystemTrack: true).isEmpty)
    }

    /// The mic and system files routinely differ in sample rate and channel
    /// count; the player must load both and report the longer duration. The
    /// previous composition-based player garbled mismatched tracks during
    /// real-time playback — this guards the per-file engine that replaced it.
    @MainActor
    func testPlayerLoadsMismatchedFormatTracks() throws {
        let folder = try temporaryFolder()
        try writeTone(to: folder.appendingPathComponent("mic.m4a"),
                      frequency: 440, duration: 0.3, sampleRate: 44_100, channels: 1)
        try writeTone(to: folder.appendingPathComponent("system.m4a"),
                      frequency: 660, duration: 0.5, sampleRate: 48_000, channels: 2)

        let player = MeetingPlayer()
        player.load(folder: folder, hasSystemTrack: true)

        XCTAssertTrue(player.isLoaded, "player should load both tracks despite differing formats")
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(player.duration, 0.5, accuracy: 0.15)   // the longer (system) track
        player.stop()
    }

    @MainActor
    func testPlayerNotLoadedWhenNoTracks() throws {
        let player = MeetingPlayer()
        player.load(folder: try temporaryFolder(), hasSystemTrack: true)
        XCTAssertFalse(player.isLoaded)
        XCTAssertEqual(player.duration, 0)
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

    private func writeTone(to url: URL, frequency: Double, duration: TimeInterval,
                           sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1) throws {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: sampleRate,
                                                 channels: channels,
                                                 interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount

        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            let samples = channelData[channel]
            for index in 0..<Int(frameCount) {
                samples[index] = Float(sin(2 * .pi * frequency * Double(index) / sampleRate) * 0.25)
            }
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: Int(channels),
            ])
        try file.write(from: buffer)
    }
}
