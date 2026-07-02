import Foundation
import FluidAudio

/// A timestamped run of speech samples (16 kHz mono), produced by VAD
/// splitting — the unit the per-span transcription engines consume.
struct SpeechSpan: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let samples: [Float]
}

/// Shared VAD-split → timestamped-span pipeline for the engines that
/// transcribe per speech region (Granite, Qwen, sherpa-onnx, Cohere). One
/// implementation so the clamping, ≤N-second splitting, and whole-track
/// fallback semantics cannot drift between engines.
extension SpeechActivity {

    static let spanSampleRate = 16_000

    /// Speech spans for `url`, each capped at `maxSegmentSeconds` when given
    /// (nil keeps whole VAD regions). Falls back to the whole decoded track
    /// (split the same way) when VAD is unavailable or finds no speech.
    /// Throws only when the audio itself cannot be decoded.
    func spans(in url: URL, maxSegmentSeconds: Double?) async throws -> [SpeechSpan] {
        if let spans = await vadSpans(in: url, maxSegmentSeconds: maxSegmentSeconds) {
            return spans
        }
        let samples = try AudioConverter().resampleAudioFile(url)
        return Self.split(samples: samples, start: 0, end: samples.count,
                          maxSegmentSeconds: maxSegmentSeconds)
    }

    /// VAD-only spans, or nil when VAD is unavailable or found no speech —
    /// for engines that need a distinct whole-track fallback (Cohere).
    func vadSpans(in url: URL, maxSegmentSeconds: Double?) async -> [SpeechSpan]? {
        guard let analysis = await speechRegions(in: url), !analysis.segments.isEmpty else {
            return nil
        }
        var spans: [SpeechSpan] = []
        for segment in analysis.segments {
            let start = max(0, segment.startSample(sampleRate: Self.spanSampleRate))
            let end = min(analysis.samples.count, segment.endSample(sampleRate: Self.spanSampleRate))
            guard end > start else { continue }
            spans.append(contentsOf: Self.split(
                samples: analysis.samples, start: start, end: end,
                maxSegmentSeconds: maxSegmentSeconds))
        }
        return spans.isEmpty ? nil : spans
    }

    private static func split(samples: [Float], start: Int, end: Int,
                              maxSegmentSeconds: Double?) -> [SpeechSpan] {
        guard end > start else { return [] }
        let rate = Double(spanSampleRate)
        let maxSamples = maxSegmentSeconds.map { max(1, Int($0 * rate)) } ?? (end - start)
        var spans: [SpeechSpan] = []
        var cursor = start
        while cursor < end {
            let next = min(cursor + maxSamples, end)
            spans.append(.init(
                start: Double(cursor) / rate,
                end: Double(next) / rate,
                samples: Array(samples[cursor..<next])))
            cursor = next
        }
        return spans
    }
}
