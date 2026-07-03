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

/// The per-span transcription loop the span-based engines (Qwen, Granite,
/// Cohere, sherpa-onnx) each used to carry a private copy of: decode one
/// span's window at a time (`SpanAudioReader`), hand the samples to the
/// engine, and keep non-empty normalized text stamped with the span's real
/// start/end. One implementation so the skip-empty-window and
/// drop-empty-text rules cannot drift between engines.
enum SpanTranscription {

    /// Sequential per-span decoding (Qwen, Granite, Cohere). `transcribe`
    /// receives the span's 16 kHz mono samples plus the span's index (Granite
    /// names its temp wavs by index); spans whose window decodes empty are
    /// skipped without calling it.
    static func segments(
        in url: URL,
        spans: [SpeechSpan],
        speaker: String = "speaker",
        transcribe: (_ samples: [Float], _ index: Int) async throws -> String
    ) async throws -> [Transcript.Segment] {
        let reader = try SpanAudioReader(url: url)
        var segments: [Transcript.Segment] = []
        for (index, span) in spans.enumerated() {
            let samples = try reader.samples(from: span.start, to: span.end)
            guard !samples.isEmpty else { continue }
            let normalized = Transcript.normalizedText(try await transcribe(samples, index))
            guard !normalized.isEmpty else { continue }
            segments.append(.init(start: span.start, end: span.end,
                                  speaker: speaker, text: normalized, confidence: nil))
        }
        return segments
    }

    /// Batch pairing (sherpa-onnx decodes all wavs in one subprocess call):
    /// stamp each returned text with its span. Extra spans without a text —
    /// the binary can return fewer results than inputs — are dropped, like
    /// empty texts.
    static func segments(pairing spans: [SpeechSpan], with texts: [String],
                         speaker: String = "speaker") -> [Transcript.Segment] {
        zip(spans, texts).compactMap { span, text in
            let normalized = Transcript.normalizedText(text)
            guard !normalized.isEmpty else { return nil }
            return .init(start: span.start, end: span.end,
                         speaker: speaker, text: normalized, confidence: nil)
        }
    }
}
