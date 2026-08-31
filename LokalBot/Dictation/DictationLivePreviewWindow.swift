import AVFoundation
import Foundation

extension DictationCoordinator {
    static func livePreviewInterval(after duration: TimeInterval) -> TimeInterval {
        min(4.0, max(1.4, duration / 8.0))
    }

    nonisolated static let previewScratchDirectoryName = "dictation-previews"

    nonisolated static func sweepOrphanedPreviewFiles(storageRoot: URL) {
        try? FileManager.default.removeItem(at: storageRoot.appendingPathComponent(
            previewScratchDirectoryName, isDirectory: true))
    }

    struct IncrementalLivePreviewWindow: Sendable {
        let url: URL
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    /// Opens the append-safe CAF at its current length and materializes only the
    /// unprocessed suffix plus a short overlap. This keeps preview I/O bounded
    /// as dictation grows instead of copying the full recording on every pass.
    static func makeIncrementalLivePreviewWindow(
        from audioURL: URL,
        storageRoot: URL,
        previousEnd: TimeInterval
    ) async throws -> IncrementalLivePreviewWindow {
        try await Task.detached(priority: .userInitiated) {
            try makeIncrementalLivePreviewWindowSynchronously(
                from: audioURL,
                storageRoot: storageRoot,
                previousEnd: previousEnd)
        }.value
    }

    nonisolated static func makeIncrementalLivePreviewWindowSynchronously(
        from audioURL: URL,
        storageRoot: URL,
        previousEnd: TimeInterval
    ) throws -> IncrementalLivePreviewWindow {
        let reader = try AVAudioFile(forReading: audioURL)
        let format = reader.processingFormat
        guard format.sampleRate > 0 else { throw DictationError.noAudio }
        let currentEnd = Double(reader.length) / format.sampleRate
        guard let range = DictationPreviewWindowPlanner.range(
            previousEnd: previousEnd,
            currentEnd: currentEnd) else {
            throw DictationError.noAudio
        }

        guard let frameBounds = DictationPreviewWindowPlanner.frameBounds(
            for: range,
            sampleRate: format.sampleRate,
            totalFrameCount: Int64(reader.length)) else {
            throw DictationError.noAudio
        }
        let startFrame = AVAudioFramePosition(frameBounds.lowerBound)
        let endFrame = AVAudioFramePosition(frameBounds.upperBound)

        let scratch = storageRoot.appendingPathComponent(
            previewScratchDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let ext = audioURL.pathExtension.isEmpty ? "caf" : audioURL.pathExtension
        let windowURL = scratch.appendingPathComponent(
            "dictation-live-window-\(UUID().uuidString).\(ext)")
        var keepWindow = false
        defer {
            if !keepWindow { try? FileManager.default.removeItem(at: windowURL) }
        }

        reader.framePosition = startFrame
        do {
            let writer = try AVAudioFile(
                forWriting: windowURL,
                settings: reader.fileFormat.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved)
            let bufferCapacity: AVAudioFrameCount = 16_384
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: bufferCapacity) else {
                throw DictationError.noAudio
            }
            var remaining = endFrame - startFrame
            var written: AVAudioFramePosition = 0
            while remaining > 0 {
                let requested = AVAudioFrameCount(min(
                    remaining,
                    AVAudioFramePosition(bufferCapacity)))
                try reader.read(into: buffer, frameCount: requested)
                guard buffer.frameLength > 0 else { break }
                try writer.write(from: buffer)
                let count = AVAudioFramePosition(buffer.frameLength)
                remaining -= count
                written += count
            }
            guard written > 0 else { throw DictationError.noAudio }
        }

        keepWindow = true
        return .init(url: windowURL, startTime: range.start, endTime: range.end)
    }
}
