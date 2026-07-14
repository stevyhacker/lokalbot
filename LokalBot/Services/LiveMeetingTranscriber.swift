import AVFoundation
import Foundation

struct LiveMeetingPreparedAudioChunk: Equatable, Sendable {
    let url: URL
    let processedFrames: Int64
    let startTime: TimeInterval
}

enum LiveMeetingAudioPreparation: Equatable, Sendable {
    case noWork
    case advance(toFrame: Int64)
    case ready(LiveMeetingPreparedAudioChunk)
}

/// Serializes the filesystem and PCM work for both live meeting tracks away
/// from the main actor. The source CAF is append-safe, so preparation opens a
/// point-in-time reader and seeks directly to the unprocessed suffix; it never
/// copies the full, ever-growing meeting file.
actor LiveMeetingAudioPreparationWorker {
    private let storageRoot: URL

    init(storageRoot: URL) {
        self.storageRoot = storageRoot
    }

    func prepareNextChunk(source: URL, processedFrames: Int64) throws
        -> LiveMeetingAudioPreparation {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: source.path) else { return .noWork }

        // Opening the append-only CAF just long enough to inspect its current
        // readable frame count avoids allocating a chunk before four fresh
        // seconds are available.
        if let availability = try? Self.availableAudio(at: source),
           LiveTranscriptChunker.nextChunk(
               processedFrames: processedFrames,
               totalFrames: availability.frames,
               sampleRate: availability.sampleRate) == nil {
            return .noWork
        }

        try Task.checkCancellation()
        let reader = try AVAudioFile(forReading: source)
        let sampleRate = reader.fileFormat.sampleRate
        guard let range = LiveTranscriptChunker.nextChunk(
            processedFrames: processedFrames,
            totalFrames: reader.length,
            sampleRate: sampleRate) else {
            return .noWork
        }

        try Task.checkCancellation()
        let frames = AVAudioFrameCount(range.upperBound - range.lowerBound)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: reader.processingFormat,
            frameCapacity: frames) else {
            return .noWork
        }
        reader.framePosition = range.lowerBound
        try reader.read(into: buffer, frameCount: frames)
        try Task.checkCancellation()
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else {
            return .noWork
        }
        var samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))

        let searchCount = min(
            samples.count,
            Int(LiveTranscriptChunker.cutSearchSeconds * sampleRate))
        if searchCount > 0 {
            let tail = Array(samples.suffix(searchCount))
            let cut = LiveTranscriptChunker.refinedCutOffset(tail: tail, sampleRate: sampleRate)
            samples.removeLast(searchCount - cut)
        }
        guard !samples.isEmpty else { return .noWork }
        let chunkEnd = range.lowerBound + Int64(samples.count)

        try Task.checkCancellation()
        guard LiveTranscriptChunker.hasSpeech(samples, sampleRate: sampleRate) else {
            return .advance(toFrame: chunkEnd)
        }

        let chunk = try scratchDirectory()
            .appendingPathComponent("chunk-\(UUID().uuidString).caf")
        var keepChunk = false
        defer {
            if !keepChunk { try? FileManager.default.removeItem(at: chunk) }
        }
        try Self.writeChunk(samples, format: reader.processingFormat, to: chunk)
        try Task.checkCancellation()
        keepChunk = true
        return .ready(LiveMeetingPreparedAudioChunk(
            url: chunk,
            processedFrames: chunkEnd,
            startTime: Double(range.lowerBound) / sampleRate))
    }

    func removePreparedChunk(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private struct AvailableAudio {
        let frames: Int64
        let sampleRate: Double
    }

    private static func availableAudio(at source: URL) throws -> AvailableAudio {
        let reader = try AVAudioFile(forReading: source)
        return AvailableAudio(frames: reader.length, sampleRate: reader.fileFormat.sampleRate)
    }

    private func scratchDirectory() throws -> URL {
        let dir = storageRoot.appendingPathComponent(
            LiveMeetingTranscriber.scratchDirectoryName,
            isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeChunk(
        _ samples: [Float],
        format: AVAudioFormat,
        to url: URL
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
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
    }
}

/// Rolling transcript of the meeting being recorded right now. The recorders
/// mirror their audio into snapshot-safe PCM tees (`mic.live.caf` /
/// `system.live.caf`, see `AudioPreviewTee`); this poller snapshots each tee,
/// cuts the unprocessed audio into small chunks at quiet points
/// (`LiveTranscriptChunker`), transcribes them with the user's selected ASR
/// engine, and publishes timestamped lines for the live meeting view.
///
/// This is a preview: the authoritative transcript is still produced by the
/// full pipeline (with diarization) after the recording stops.
///
/// Lifecycle: `AppState` calls `prepare(folder:)` when a recording starts and
/// `stop()` when it ends, but transcription only actually runs after
/// `activate()` — the live meeting view calls it on first show, so meetings
/// nobody watches cost zero ASR cycles. Once activated, the opt-in
/// carries across calendar-handoff splits (a fresh `prepare` resumes).
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

    private let settings: () -> AppSettings
    private let audioPreparationWorker: LiveMeetingAudioPreparationWorker
    private var task: Task<Void, Never>?
    private var generation = 0
    private var pendingFolder: URL?
    private var hasTranscribedOnce = false
    /// Keep the panel bounded on very long meetings.
    private static let maxLines = 400
    private static let maxConsecutiveFailures = 3

    nonisolated static let scratchDirectoryName = "live-previews"

    init(storageRoot: URL, settings: @escaping () -> AppSettings) {
        self.settings = settings
        self.audioPreparationWorker = LiveMeetingAudioPreparationWorker(storageRoot: storageRoot)
    }

    /// Snapshots are deleted per-use, but a crash mid-chunk orphans them —
    /// call once at launch to reclaim the scratch directory.
    static func sweepOrphanedSnapshots(storageRoot: URL) {
        try? FileManager.default.removeItem(
            at: storageRoot.appendingPathComponent(scratchDirectoryName, isDirectory: true))
    }

    /// A recording started (or split to a new meeting folder). Doesn't
    /// transcribe yet — that costs ASR passes for the whole meeting — but if
    /// the user had already opened the panel this session, resume seamlessly.
    func prepare(folder: URL) {
        let resume = isRunning
        cancelWork()
        pendingFolder = folder
        lines = []
        statusMessage = nil
        if resume { activate() }
    }

    /// The live meeting view appeared: actually start transcribing. Idempotent
    /// while running; a no-op when no recording is prepared.
    func activate() {
        guard !isRunning, let folder = pendingFolder else { return }
        generation += 1
        let session = generation
        hasTranscribedOnce = false
        isRunning = true
        task = Task { [weak self] in
            await self?.run(folder: folder, session: session)
        }
    }

    /// The recording ended.
    func stop() {
        cancelWork()
        pendingFolder = nil
        lines = []
        statusMessage = nil
    }

    private func cancelWork() {
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

    /// Prepare one tee's next chunk off-main, transcribe it, and append lines.
    /// Returns the new processed-frame position, or nil when there's nothing
    /// new to do (tee missing, or not enough fresh audio yet).
    private func transcribeNextChunk(of track: TrackState, folder: URL,
                                     session: Int) async throws -> Int64? {
        let source = folder.appendingPathComponent(track.fileName)
        let preparation = try await audioPreparationWorker.prepareNextChunk(
            source: source,
            processedFrames: track.processedFrames)
        switch preparation {
        case .noWork:
            return nil
        case .advance(let frame):
            return frame
        case .ready(let prepared):
            do {
                let advanced = try await transcribePreparedChunk(
                    prepared,
                    track: track,
                    session: session)
                await audioPreparationWorker.removePreparedChunk(at: prepared.url)
                return advanced
            } catch {
                await audioPreparationWorker.removePreparedChunk(at: prepared.url)
                throw error
            }
        }
    }

    private func transcribePreparedChunk(
        _ prepared: LiveMeetingPreparedAudioChunk,
        track: TrackState,
        session: Int
    ) async throws -> Int64? {
        isWorking = true
        // The first pass may block on model load for a while — say so instead
        // of leaving the panel on a bare "Listening…".
        if !hasTranscribedOnce {
            statusMessage = "Preparing the transcription model…"
        }
        let config = settings()
        let transcript = try await config.transcriptionModel.engine.transcribe(
            audio: prepared.url,
            language: config.transcriptionLanguage.code)
        try Task.checkCancellation()
        guard generation == session else { return nil }
        hasTranscribedOnce = true
        statusMessage = nil

        let fresh = transcript.segments.compactMap { segment -> Line? in
            let text = segment.displayText
            guard !text.isEmpty else { return nil }
            return Line(
                time: prepared.startTime + segment.start,
                speaker: track.speaker,
                text: text)
        }
        if !fresh.isEmpty {
            lines = Array(((lines + fresh).sorted { $0.time < $1.time }).suffix(Self.maxLines))
        }
        return prepared.processedFrames
    }
}
