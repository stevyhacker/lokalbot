import AVFoundation

/// Best-effort side-channel writer that mirrors a recorder's buffers into a
/// small snapshot-safe PCM `.caf` (16 kHz mono float32 — what ASR models
/// resample to anyway, ~230 MB/hour). The primary meeting tracks are AAC
/// `.m4a`, whose MP4 container is unreadable until the writer closes, so the
/// live transcript needs this tee: CAF is append-only and a mid-write copy
/// always decodes (the same property dictation's live preview relies on).
///
/// Strictly non-fatal: a failed setup returns `nil`, a failed write disables
/// the tee, and the meeting recording never notices either way. Each recorder
/// owns one instance and calls `write` from its single serial write context.
final class AudioPreviewTee {

    static let micFileName = "mic.live.caf"
    static let systemFileName = "system.live.caf"

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let teeFormat: AVAudioFormat

    init?(url: URL, sourceFormat: AVAudioFormat) {
        guard let teeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000,
                                            channels: 1,
                                            interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: teeFormat) else {
            return nil
        }
        self.teeFormat = teeFormat
        self.converter = converter
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: teeFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        do {
            try? FileManager.default.removeItem(at: url)
            file = try AVAudioFile(forWriting: url,
                                   settings: settings,
                                   commonFormat: teeFormat.commonFormat,
                                   interleaved: teeFormat.isInterleaved)
        } catch {
            NSLog("AudioPreviewTee setup failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Resample + downmix `buffer` (in the source format) into the tee file.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard let file, let converter, buffer.frameLength > 0 else { return }
        let ratio = teeFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: teeFormat, frameCapacity: capacity) else {
            return
        }
        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            // Disable rather than spam the audio thread with retries.
            NSLog("AudioPreviewTee convert failed: \(conversionError?.localizedDescription ?? "unknown")")
            self.file = nil
            return
        }
        guard output.frameLength > 0 else { return }
        do {
            try file.write(from: output)
        } catch {
            NSLog("AudioPreviewTee write failed: \(error.localizedDescription)")
            self.file = nil
        }
    }

    func close() {
        file = nil   // closes the caf
        converter = nil
    }
}
