import AVFoundation
import Foundation

/// Decodes 16 kHz mono Float32 windows of an audio file on demand — one span
/// at a time. Transcription used to decode a whole track up front (~230 MB of
/// samples per recorded hour per track) and then copy every speech span out of
/// it; reading each span's window straight from the file keeps at most one
/// span (seconds of audio, a few MB) resident while the ASR model works.
///
/// Not Sendable (wraps an `AVAudioFile`): create one inside the actor-isolated
/// transcribe call and iterate spans in order — reads seek forward only.
final class SpanAudioReader {
    static let sampleRate = 16_000.0

    enum ReaderError: Error {
        case formatUnavailable
        case bufferAllocationFailed
    }

    private let file: AVAudioFile
    private let outputFormat: AVAudioFormat

    /// Track length in seconds, from the container header — no decode.
    var duration: TimeInterval {
        Double(file.length) / file.processingFormat.sampleRate
    }

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
            channels: 1, interleaved: false) else {
            throw ReaderError.formatUnavailable
        }
        outputFormat = format
    }

    /// Decodes the `[start, end)` window (seconds on the track timeline) to
    /// 16 kHz mono samples, clamped to the file's bounds. An empty or fully
    /// out-of-range window returns `[]`.
    func samples(from start: TimeInterval, to end: TimeInterval) throws -> [Float] {
        let sourceFormat = file.processingFormat
        let sourceRate = sourceFormat.sampleRate
        let firstFrame = min(AVAudioFramePosition(max(0, start) * sourceRate), file.length)
        let lastFrame = min(AVAudioFramePosition(max(0, end) * sourceRate), file.length)
        guard lastFrame > firstFrame else { return [] }

        file.framePosition = firstFrame
        let frameCount = AVAudioFrameCount(lastFrame - firstFrame)
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw ReaderError.bufferAllocationFailed
        }
        try file.read(into: sourceBuffer, frameCount: frameCount)

        // Already 16 kHz mono float (e.g. the test-fixture WAVs): no conversion.
        if sourceFormat.sampleRate == outputFormat.sampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32 {
            return Self.floats(of: sourceBuffer)
        }
        return try Self.convert(sourceBuffer, to: outputFormat)
    }

    /// One-shot rate/channel conversion of a single already-read window. A
    /// fresh converter per window is deliberate: its cost is trivial next to
    /// the decode + ASR work, and it avoids carrying resampler state across
    /// non-adjacent windows (spans skip the silence between them).
    private static func convert(
        _ source: AVAudioPCMBuffer, to outputFormat: AVAudioFormat
    ) throws -> [Float] {
        guard let converter = AVAudioConverter(from: source.format, to: outputFormat) else {
            throw ReaderError.formatUnavailable
        }
        // No priming: each window is converted in isolation, and priming would
        // swallow the first ~milliseconds of every span boundary.
        converter.primeMethod = .none
        var fed = false
        let input: AVAudioConverterInputBlock = { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return source
        }
        let ratio = outputFormat.sampleRate / source.format.sampleRate
        var result: [Float] = []
        result.reserveCapacity(Int(Double(source.frameLength) * ratio) + 16)
        while true {
            guard let chunk = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: 8_192) else {
                throw ReaderError.bufferAllocationFailed
            }
            var conversionError: NSError?
            let status = converter.convert(to: chunk, error: &conversionError, withInputFrom: input)
            if let conversionError { throw conversionError }
            result.append(contentsOf: Self.floats(of: chunk))
            if status == .endOfStream || status == .error || chunk.frameLength == 0 { break }
        }
        return result
    }

    private static func floats(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}
