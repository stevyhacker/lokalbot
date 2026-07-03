import AVFoundation
import Foundation

/// Rolling transcript of the meeting being recorded right now. The recorders
/// mirror their audio into snapshot-safe PCM tees (`mic.live.caf` /
/// `system.live.caf`, see `AudioPreviewTee`); this poller snapshots each tee,
/// cuts the unprocessed audio into small chunks at quiet points
/// (`LiveTranscriptChunker`), transcribes them with the user's selected ASR
/// engine, and publishes timestamped lines for the live panel.
///
/// This is a preview: the authoritative transcript is still produced by the
/// full pipeline (with diarization) after the recording stops. Started and
/// stopped by `AppState` from the recording status.
@MainActor
final class LiveMeetingTranscriber: ObservableObject {

    struct Line: Identifiable, Equatable {
        let id = UUID()
        /// Seconds since the recording started.
        let time: TimeInterval
        /// "me" (mic) or "them" (system audio).
        let speaker: String
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var isWorking = false
    @Published private(set) var isRunning = false
    /// Surfaced in the panel when transcription keeps failing.
    @Published private(set) var statusMessage: String?

    private let storageRoot: URL
    private let settings: () -> AppSettings
    private var task: Task<Void, Never>?
    private var generation = 0
    /// Keep the panel bounded on very long meetings.
    private static let maxLines = 400
    private static let maxConsecutiveFailures = 3

    init(storageRoot: URL, settings: @escaping () -> AppSettings) {
        self.storageRoot = storageRoot
        self.settings = settings
    }

    func start(folder: URL) {
        stop()
        generation += 1
        let session = generation
        lines = []
        statusMessage = nil
        isRunning = true
        task = Task { [weak self] in
            await self?.run(folder: folder, session: session)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        generation += 1
        isRunning = false
        isWorking = false
    }

    // MARK: - Poll loop

    private struct TrackState {
        let fileName: String
        let speaker: String
        var processedFrames: Int64 = 0
    }

    private func run(folder: URL, session: Int) async {
        defer {
            if generation == session {
                isRunning = false
                isWorking = false
            }
        }
        var tracks = [TrackState(fileName: AudioPreviewTee.micFileName, speaker: "me"),
                      TrackState(fileName: AudioPreviewTee.systemFileName, speaker: "them")]
        var consecutiveFailures = 0
        try? await Task.sleep(for: .seconds(LiveTranscriptChunker.minChunkSeconds))
        while !Task.isCancelled, generation == session {
            var didWork = false
            for index in tracks.indices {
                guard !Task.isCancelled, generation == session else { return }
                do {
                    if let advanced = try await transcribeNextChunk(of: tracks[index],
                                                                    folder: folder,
                                                                    session: session) {
                        tracks[index].processedFrames = advanced
                        didWork = true
                        consecutiveFailures = 0
                    }
                } catch is CancellationError {
                    return
                } catch {
                    consecutiveFailures += 1
                    lokalbotLog("live transcript chunk failed track=\(tracks[index].fileName) error=\(error.localizedDescription)")
                    if consecutiveFailures >= Self.maxConsecutiveFailures {
                        statusMessage = "Live transcription is unavailable — the full transcript still arrives after the meeting."
                        return
                    }
                }
            }
            isWorking = false
            try? await Task.sleep(for: .seconds(didWork ? 0.5 : 2.0))
        }
    }

    /// Snapshot one tee, transcribe its next chunk, and append the lines.
    /// Returns the new processed-frame position, or nil when there's nothing
    /// new to do (tee missing, or not enough fresh audio yet).
    private func transcribeNextChunk(of track: TrackState, folder: URL,
                                     session: Int) async throws -> Int64? {
        let source = folder.appendingPathComponent(track.fileName)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }

        let scratch = try scratchDirectory()
        let snapshot = scratch.appendingPathComponent("snap-\(UUID().uuidString).caf")
        try FileManager.default.copyItem(at: source, to: snapshot)
        defer { try? FileManager.default.removeItem(at: snapshot) }

        let reader = try AVAudioFile(forReading: snapshot)
        let sampleRate = reader.fileFormat.sampleRate
        guard let range = LiveTranscriptChunker.nextChunk(processedFrames: track.processedFrames,
                                                          totalFrames: reader.length,
                                                          sampleRate: sampleRate) else {
            return nil
        }

        let frames = AVAudioFrameCount(range.upperBound - range.lowerBound)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
                                            frameCapacity: frames) else { return nil }
        reader.framePosition = range.lowerBound
        try reader.read(into: buffer, frameCount: frames)
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { return nil }
        var samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))

        // Prefer to end the chunk in a pause instead of mid-word.
        let searchCount = min(samples.count, Int(LiveTranscriptChunker.cutSearchSeconds * sampleRate))
        if searchCount > 0 {
            let tail = Array(samples.suffix(searchCount))
            let cut = LiveTranscriptChunker.refinedCutOffset(tail: tail, sampleRate: sampleRate)
            samples.removeLast(searchCount - cut)
        }
        guard !samples.isEmpty else { return nil }
        let chunkEnd = range.lowerBound + Int64(samples.count)

        // Nothing but room tone: advance silently, no ASR pass needed.
        if LiveTranscriptChunker.isSilent(samples) { return chunkEnd }

        let chunk = scratch.appendingPathComponent("chunk-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: chunk) }
        try writeChunk(samples, format: reader.processingFormat, to: chunk)

        isWorking = true
        let config = settings()
        let transcript = try await config.transcriptionModel.engine.transcribe(
            audio: chunk,
            language: config.transcriptionLanguage.code)
        try Task.checkCancellation()
        guard generation == session else { return nil }

        let offset = Double(range.lowerBound) / sampleRate
        let fresh = transcript.segments.compactMap { segment -> Line? in
            let text = segment.displayText
            guard !text.isEmpty else { return nil }
            return Line(time: offset + segment.start, speaker: track.speaker, text: text)
        }
        if !fresh.isEmpty {
            lines = Array(((lines + fresh).sorted { $0.time < $1.time }).suffix(Self.maxLines))
        }
        return chunkEnd
    }

    private func scratchDirectory() throws -> URL {
        let dir = storageRoot.appendingPathComponent("live-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeChunk(_ samples: [Float], format: AVAudioFormat, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        samples.withUnsafeBufferPointer { pointer in
            channel.update(from: pointer.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }
}
