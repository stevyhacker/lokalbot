import Foundation
import FluidAudio

/// A timestamped run of speech on the track timeline, produced by VAD
/// splitting — timings only. Engines decode each span's samples on demand
/// with `SpanAudioReader`, so a whole decoded track (~230 MB per recorded
/// hour) is never resident during transcription.
struct SpeechSpan: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
}

/// Shared VAD-split → timestamped-span pipeline for the engines that
/// transcribe per speech region (Granite, Qwen, sherpa-onnx, Cohere). One
/// implementation so the clamping, ≤N-second splitting, and whole-track
/// fallback semantics cannot drift between engines.
extension SpeechActivity {

    static let spanSampleRate = 16_000

    /// Speech spans for `url`, each capped at `maxSegmentSeconds` when given
    /// (nil keeps whole VAD regions). Falls back to the whole track (split the
    /// same way) when VAD is unavailable or finds no speech. Throws only when
    /// the audio itself cannot be opened.
    func spans(in url: URL, maxSegmentSeconds: Double?) async throws -> [SpeechSpan] {
        if let spans = await vadSpans(in: url, maxSegmentSeconds: maxSegmentSeconds) {
            return spans
        }
        let duration = try SpanAudioReader(url: url).duration
        return Self.split(start: 0, end: duration, maxSegmentSeconds: maxSegmentSeconds)
    }

    /// VAD-only spans, or nil when VAD is unavailable or found no speech —
    /// for engines that need a distinct whole-track fallback (Cohere).
    func vadSpans(in url: URL, maxSegmentSeconds: Double?) async -> [SpeechSpan]? {
        guard let segments = await speechSegments(in: url), !segments.isEmpty else {
            return nil
        }
        var spans: [SpeechSpan] = []
        for segment in segments {
            let start = max(0, segment.startTime)
            guard segment.endTime > start else { continue }
            spans.append(contentsOf: Self.split(
                start: start, end: segment.endTime,
                maxSegmentSeconds: maxSegmentSeconds))
        }
        return spans.isEmpty ? nil : spans
    }

    /// Pure ≤N-second splitting on the time axis. Internal (not private) so
    /// the boundary arithmetic is unit-testable without audio files.
    static func split(start: TimeInterval, end: TimeInterval,
                      maxSegmentSeconds: Double?) -> [SpeechSpan] {
        guard end > start else { return [] }
        let minLength = 1.0 / Double(spanSampleRate)
        let maxLength = maxSegmentSeconds.map { max($0, minLength) } ?? (end - start)
        var spans: [SpeechSpan] = []
        var cursor = start
        while cursor < end {
            let next = min(cursor + maxLength, end)
            spans.append(.init(start: cursor, end: next))
            cursor = next
        }
        return spans
    }
}
