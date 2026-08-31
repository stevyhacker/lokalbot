import Foundation

/// Produces a copy of the microphone track with the remote side cancelled out,
/// for transcription only.
///
/// The original `mic.m4a` is never touched: it stays the recording the user can
/// play back, and this writes a 16 kHz mono sidecar that the ASR engines
/// consume (they resample to exactly that anyway). Working on the recorded
/// files rather than inside the capture path costs a codec generation — both
/// tracks are AAC by now — but it means meetings already in the library can be
/// cleaned by re-running transcription, which a capture-time canceller can
/// never do.
enum EchoCancelledTrack {

    struct Report: Equatable, Sendable {
        /// How far the microphone lagged the system track.
        var delaySeconds: TimeInterval
        /// Energy removed, in dB. Near zero means there was no echo to find —
        /// the expected outcome on headphones.
        var echoReturnLossDB: Double
        var processedSeconds: TimeInterval
    }

    /// Streamed in windows so a long meeting never has both tracks resident:
    /// an hour of 16 kHz mono is 230 MB per track decoded whole.
    static let chunkSeconds: TimeInterval = 30
    /// Windows the delay estimate is taken from, as fractions of the track.
    static let probePoints: [Double] = [0.2, 0.5, 0.8]
    static let probeSeconds: TimeInterval = 20

    /// Voice Isolation produced only 2.6-3.1 dB on the recordings used to
    /// validate this stage, while Standard mode produced at least 12.9 dB.
    /// Keep a deliberate gap between those ranges: a marginal result is more
    /// safely transcribed from the untouched microphone track.
    static let minimumAcceptedEchoReturnLossDB = 6.0

    enum StageError: Error {
        case noOverlap
    }

    /// Runs decode and DSP on a utility executor rather than the caller's
    /// actor. Cancelling the awaiting task also cancels the worker, whose
    /// cooperative checks remove any partial destination before returning.
    static func write(microphone: URL, reference: URL, to destination: URL) async throws -> Report {
        let worker = Task.detached(priority: .utility) {
            try writeSynchronously(microphone: microphone,
                                   reference: reference,
                                   to: destination)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Fail open to the original microphone whenever the score is uncertain or
    /// falls in the known Voice Isolation degradation range.
    static func shouldUse(_ report: Report) -> Bool {
        report.echoReturnLossDB.isFinite
            && report.echoReturnLossDB >= minimumAcceptedEchoReturnLossDB
    }

    private static func writeSynchronously(
        microphone: URL,
        reference: URL,
        to destination: URL
    ) throws -> Report {
        do {
            return try writeFile(microphone: microphone,
                                 reference: reference,
                                 to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func writeFile(
        microphone: URL,
        reference: URL,
        to destination: URL
    ) throws -> Report {
        try Task.checkCancellation()
        let rate = SpanAudioReader.sampleRate
        let microphoneDuration = try SpanAudioReader(url: microphone).duration
        let referenceDuration = try SpanAudioReader(url: reference).duration
        let overlapDuration = min(microphoneDuration, referenceDuration)
        guard overlapDuration > 1 else { throw StageError.noOverlap }

        let delaySamples = try estimateDelay(microphone: microphone,
                                             reference: reference,
                                             duration: overlapDuration)
        let delaySeconds = Double(delaySamples) / rate

        // Fresh readers: the probes above seek forward through the track and
        // `SpanAudioReader` does not seek back.
        let micReader = try SpanAudioReader(url: microphone)
        let referenceReader = try SpanAudioReader(url: reference)
        var canceller = EchoCanceller()
        let writer = try WavWriter(url: destination, sampleRate: Int(rate))

        var position: TimeInterval = 0
        var processedSamples = 0
        while position < microphoneDuration {
            try Task.checkCancellation()
            let end = min(position + chunkSeconds, microphoneDuration)
            let mic = try micReader.samples(from: position, to: end)
            guard !mic.isEmpty else { break }
            let aligned = try alignedReference(referenceReader,
                                               from: position - delaySeconds,
                                               to: end - delaySeconds,
                                               count: mic.count)
            let cancelled = try canceller.process(microphone: mic, reference: aligned)
            try Task.checkCancellation()
            try writer.append(cancelled)
            processedSamples += cancelled.count
            position = end
        }
        try Task.checkCancellation()
        try writer.finish()

        return Report(delaySeconds: delaySeconds,
                      echoReturnLossDB: canceller.echoReturnLossDB,
                      processedSeconds: Double(processedSamples) / rate)
    }

    /// The reference window for one chunk, zero-padded where it runs off the
    /// front of the track and trimmed to the microphone's length — the two
    /// must line up sample for sample or the filter has nothing to learn.
    private static func alignedReference(_ reader: SpanAudioReader,
                                         from start: TimeInterval,
                                         to end: TimeInterval,
                                         count: Int) throws -> [Float] {
        var samples: [Float] = []
        if start < 0 {
            let missing = Int((-start) * SpanAudioReader.sampleRate)
            samples.append(contentsOf: [Float](repeating: 0, count: missing))
        }
        samples.append(contentsOf: try reader.samples(from: max(0, start), to: max(0, end)))
        if samples.count > count {
            samples.removeLast(samples.count - count)
        } else if samples.count < count {
            samples.append(contentsOf: [Float](repeating: 0, count: count - samples.count))
        }
        return samples
    }

    /// Median of several probes across the track. One probe can land on a
    /// stretch where nobody speaks, and the delay itself moves as the two
    /// capture clocks drift, so the middle of several beats any single one.
    private static func estimateDelay(microphone: URL, reference: URL,
                                      duration: TimeInterval) throws -> Int {
        let micReader = try SpanAudioReader(url: microphone)
        let referenceReader = try SpanAudioReader(url: reference)
        var estimates: [Int] = []
        for point in probePoints {
            try Task.checkCancellation()
            let start = max(0, min(duration - probeSeconds, duration * point))
            guard start >= 0 else { continue }
            let mic = try micReader.samples(from: start, to: start + probeSeconds)
            let remote = try referenceReader.samples(from: start, to: start + probeSeconds)
            try Task.checkCancellation()
            guard !mic.isEmpty, !remote.isEmpty else { continue }
            estimates.append(EchoDelayEstimator.delay(microphone: mic, reference: remote,
                                                      sampleRate: SpanAudioReader.sampleRate))
        }
        guard !estimates.isEmpty else { return 0 }
        return estimates.sorted()[estimates.count / 2]
    }
}

/// Minimal streaming 16-bit PCM WAV writer. The header's two size fields are
/// only known at the end, so they are written as placeholders and patched on
/// `finish()` — which is what lets a 50-minute track be written without ever
/// holding it in memory.
final class WavWriter {
    private let handle: FileHandle
    private var bytesWritten = 0

    init(url: URL, sampleRate: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: 0))
    }

    func append(_ samples: [Float]) throws {
        var data = Data(capacity: samples.count * 2)
        for (index, sample) in samples.enumerated() {
            if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * 32_767).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: data)
        bytesWritten += data.count
    }

    func finish() throws {
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.le32(UInt32(36 + bytesWritten)))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Self.le32(UInt32(bytesWritten)))
        try handle.close()
    }

    private static func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func le16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func header(sampleRate: Int, dataBytes: Int) -> Data {
        var data = Data(capacity: 44)
        data.append(Data("RIFF".utf8))
        data.append(le32(UInt32(36 + dataBytes)))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        data.append(le32(16))
        data.append(le16(1))                                 // PCM
        data.append(le16(1))                                 // mono
        data.append(le32(UInt32(sampleRate)))
        data.append(le32(UInt32(sampleRate * 2)))            // byte rate
        data.append(le16(2))                                 // block align
        data.append(le16(16))                                // bits per sample
        data.append(Data("data".utf8))
        data.append(le32(UInt32(dataBytes)))
        return data
    }
}
