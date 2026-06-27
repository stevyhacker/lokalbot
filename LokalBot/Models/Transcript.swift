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
    /// Per-meeting display-name overrides keyed by the stable speaker label
    /// stored on each segment, e.g. "them 2" -> "Ana".
    var speakerAliases: [String: String]

    init(segments: [Segment], engine: String, speakerAliases: [String: String] = [:]) {
        self.segments = segments
        self.engine = engine
        self.speakerAliases = Self.normalizedAliases(speakerAliases)
    }

    private enum CodingKeys: String, CodingKey {
        case segments, engine, speakerAliases
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segments = try container.decode([Segment].self, forKey: .segments)
        engine = try container.decode(String.self, forKey: .engine)
        let decodedAliases = try container.decodeIfPresent([String: String].self, forKey: .speakerAliases) ?? [:]
        speakerAliases = Self.normalizedAliases(decodedAliases)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(segments, forKey: .segments)
        try container.encode(engine, forKey: .engine)
        if !speakerAliases.isEmpty {
            try container.encode(speakerAliases, forKey: .speakerAliases)
        }
    }

    /// Renders `transcript.md` — "[00:14:32] **Me:** …"
    var markdown: String {
        segments.compactMap { seg in
            let text = seg.displayText
            guard !text.isEmpty else { return nil }
            return "**[\(Self.stamp(seg.start))] \(displaySpeaker(for: seg.speaker)):** \(text)"
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

    func displaySpeaker(for speaker: String) -> String {
        speakerAliases[Self.canonicalSpeakerKey(speaker)] ?? Self.defaultSpeakerName(for: speaker)
    }

    mutating func setSpeakerAlias(_ alias: String?, for speaker: String) {
        let key = Self.canonicalSpeakerKey(speaker)
        guard !key.isEmpty else { return }
        guard let alias = Self.normalizedAlias(alias ?? ""),
              alias.caseInsensitiveCompare(Self.defaultSpeakerName(for: speaker)) != .orderedSame
        else {
            speakerAliases.removeValue(forKey: key)
            return
        }
        speakerAliases[key] = alias
    }

    func speakerAlias(for speaker: String) -> String? {
        speakerAliases[Self.canonicalSpeakerKey(speaker)]
    }

    static func defaultSpeakerName(for speaker: String) -> String {
        let trimmed = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Speaker" }
        switch canonicalSpeakerKey(trimmed) {
        case "me": return "Me"
        case "them": return "Them"
        default: return trimmed.capitalized
        }
    }

    static func canonicalSpeakerKey(_ speaker: String) -> String {
        speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedAlias(_ alias: String) -> String? {
        let collapsed = alias.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func normalizedAliases(_ aliases: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in aliases {
            let canonical = canonicalSpeakerKey(key)
            guard !canonical.isEmpty, let alias = normalizedAlias(value) else { continue }
            result[canonical] = alias
        }
        return result
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
