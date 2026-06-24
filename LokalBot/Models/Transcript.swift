import Foundation

/// Speaker-attributed transcript of a meeting. Persisted as `transcript.json`
/// next to the audio; rendered to `transcript.md` for human reading.
///
/// Lives in `Models/` (not `Engines/`) because the embedded `lokalbot-cli`
/// reads it without linking WhisperKit / FluidAudio. The transcription engines
/// fill it in, but it's just a data shape — no engine dependency.
struct Transcript: Codable {
    struct Segment: Codable {
        var start: TimeInterval
        var end: TimeInterval
        var speaker: String      // "me" | "them" | diarized label
        var text: String
        var confidence: Double?
    }
    var segments: [Segment]
    var engine: String

    /// Renders `transcript.md` — "[00:14:32] **Me:** …"
    var markdown: String {
        segments.compactMap { seg in
            let text = seg.displayText
            guard !text.isEmpty else { return nil }
            return "**[\(Self.stamp(seg.start))] \(seg.speaker.capitalized):** \(text)"
        }.joined(separator: "\n\n")
    }

    /// Merge per-track transcripts (mic = "me", system = "them") by timestamp.
    static func merged(_ tracks: [Transcript]) -> Transcript {
        Transcript(
            segments: tracks.flatMap(\.segments).compactMap { segment in
                var normalized = segment
                normalized.text = segment.displayText
                return normalized.text.isEmpty ? nil : normalized
            }.sorted { $0.start < $1.start },
            engine: tracks.first?.engine ?? "unknown")
    }

    static func stamp(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// Whisper-family models can emit control/timestamp tokens as plain text.
    /// Persist and render only the human transcript text.
    static func normalizedText(_ raw: String) -> String {
        let withoutControlTokens = raw.replacingOccurrences(
            of: #"<\|[^>]*\|>"#,
            with: " ",
            options: .regularExpression)
        let collapsedWhitespace = withoutControlTokens.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsedWhitespace.rangeOfCharacter(from: .alphanumerics) != nil else {
            return ""
        }
        return collapsedWhitespace
    }
}

extension Transcript.Segment {
    var displayText: String {
        Transcript.normalizedText(text)
    }
}
