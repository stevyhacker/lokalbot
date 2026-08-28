import Foundation

/// Speaker-attributed transcript of a meeting. Persisted as `transcript.json`
/// next to the audio; rendered to `transcript.md` for human reading.
///
/// Lives in `Models/` (not `Engines/`) because the embedded `lokalbot-cli`
/// reads it without linking WhisperKit / FluidAudio. The transcription engines
/// fill it in, but it's just a data shape — no engine dependency.
struct Transcript: Codable {
    struct Segment: Codable, Equatable {
        enum TimingPrecision: String, Codable, Sendable {
            /// The text covers a fallback window or whole track; its words are
            /// not localized closely enough to support destructive filtering.
            case coarse
            /// The text was transcribed from a VAD/ASR speech span with real
            /// start and end boundaries.
            case span
            /// The boundaries were derived from timestamped ASR tokens.
            case token

            var isBleedFilterSafe: Bool { self == .span || self == .token }
        }

        var start: TimeInterval
        var end: TimeInterval
        var speaker: String      // "me" | "them" | diarized label
        var text: String
        var confidence: Double?
        /// Optional keeps older persisted transcripts source-compatible. A
        /// missing value is unknown and therefore never used for deletion.
        var timingPrecision: TimingPrecision?
    }

    /// A compact, timestamp-anchored turn used only for model prompts. The
    /// persisted transcript and playback rows keep their original segment
    /// boundaries; summarization can merge nearby runs from the same speaker
    /// without paying the token cost of a label and timestamp on every ASR
    /// span.
    struct PromptTurn: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var speaker: String
        var text: String
    }

    /// Immutable, UI-ready segment data. Building this value performs the
    /// control-token/whitespace normalization once when a transcript changes,
    /// instead of once per row on every playback timer tick.
    struct DisplaySegment: Equatable, Identifiable {
        let id: Int
        let segment: Segment
        let text: String
        let speakerLabel: String
        let speakerKey: String
        let hasSpeakerAlias: Bool
    }

    /// Cached transcript presentation plus a chronological interval index for
    /// playback highlighting. `segments` deliberately remains in source order;
    /// only the private lookup is sorted, so malformed/legacy files do not
    /// silently reorder what the user sees.
    struct DisplayIndex {
        let segments: [DisplaySegment]

        private struct Interval {
            let id: Int
            let start: TimeInterval
            let end: TimeInterval
        }

        private let intervals: [Interval]
        /// Maximum effective end among `intervals[0...index]`. This lets an
        /// active-segment query stop as soon as no earlier interval can overlap.
        private let prefixMaximumEnds: [TimeInterval]

        init(transcript: Transcript? = nil) {
            guard let transcript else {
                segments = []
                intervals = []
                prefixMaximumEnds = []
                return
            }

            segments = transcript.segments.enumerated().compactMap { index, segment in
                let text = segment.displayText
                guard !text.isEmpty else { return nil }
                let speakerKey = Transcript.canonicalSpeakerKey(segment.speaker)
                return DisplaySegment(
                    id: index,
                    segment: segment,
                    text: text,
                    speakerLabel: transcript.displaySpeaker(for: segment.speaker),
                    speakerKey: speakerKey,
                    hasSpeakerAlias: transcript.speakerAliases[speakerKey] != nil)
            }

            intervals = segments.map { display in
                Interval(
                    id: display.id,
                    start: display.segment.start,
                    end: max(display.segment.end, display.segment.start + 0.5))
            }.sorted {
                if $0.start == $1.start { return $0.id < $1.id }
                return $0.start < $1.start
            }

            var maximumEnd = -TimeInterval.infinity
            prefixMaximumEnds = intervals.map { interval in
                maximumEnd = max(maximumEnd, interval.end)
                return maximumEnd
            }
        }

        /// IDs of all visible segments containing `time`. A binary search skips
        /// future segments, and the prefix maxima bound the backwards overlap
        /// scan. Returning every overlap preserves simultaneous-speaker
        /// highlighting from the previous per-row comparison.
        func activeSegmentIDs(at time: TimeInterval) -> Set<Int> {
            var lowerBound = 0
            var upperBound = intervals.count
            while lowerBound < upperBound {
                let middle = lowerBound + (upperBound - lowerBound) / 2
                if intervals[middle].start <= time {
                    lowerBound = middle + 1
                } else {
                    upperBound = middle
                }
            }

            var active: Set<Int> = []
            var index = lowerBound - 1
            while index >= 0, prefixMaximumEnds[index] > time {
                let interval = intervals[index]
                if time < interval.end {
                    active.insert(interval.id)
                }
                index -= 1
            }
            return active
        }
    }

    var segments: [Segment]
    var engine: String
    /// Per-meeting display-name overrides keyed by the stable speaker label
    /// stored on each segment, e.g. "them 2" -> "Ana".
    var speakerAliases: [String: String]
    /// Opaque calendar-participant IDs selected for speaker aliases. Email
    /// addresses remain in meeting metadata and never enter the transcript.
    var speakerCalendarIdentityIDs: [String: String]

    init(
        segments: [Segment],
        engine: String,
        speakerAliases: [String: String] = [:],
        speakerCalendarIdentityIDs: [String: String] = [:]
    ) {
        self.segments = segments
        self.engine = engine
        self.speakerAliases = Self.normalizedAliases(speakerAliases)
        self.speakerCalendarIdentityIDs = Self.normalizedIdentityAssignments(
            speakerCalendarIdentityIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case segments, engine, speakerAliases, speakerCalendarIdentityIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segments = try container.decode([Segment].self, forKey: .segments)
        engine = try container.decode(String.self, forKey: .engine)
        let decodedAliases = try container.decodeIfPresent([String: String].self, forKey: .speakerAliases) ?? [:]
        speakerAliases = Self.normalizedAliases(decodedAliases)
        let decodedIdentityIDs = try container.decodeIfPresent(
            [String: String].self,
            forKey: .speakerCalendarIdentityIDs) ?? [:]
        speakerCalendarIdentityIDs = Self.normalizedIdentityAssignments(decodedIdentityIDs)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(segments, forKey: .segments)
        try container.encode(engine, forKey: .engine)
        if !speakerAliases.isEmpty {
            try container.encode(speakerAliases, forKey: .speakerAliases)
        }
        if !speakerCalendarIdentityIDs.isEmpty {
            try container.encode(
                speakerCalendarIdentityIDs,
                forKey: .speakerCalendarIdentityIDs)
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

    /// Stable source IDs used by outcome extraction and evidence links. The ID
    /// is derived from immutable source order and timing, so re-opening the same
    /// transcript resolves citations without adding migration-only fields to
    /// every legacy segment.
    func segmentID(at index: Int) -> String {
        guard segments.indices.contains(index) else { return "segment-invalid" }
        let segment = segments[index]
        return String(
            format: "segment-%04d-%010lld-%010lld",
            index,
            Int64((segment.start * 1_000).rounded()),
            Int64((segment.end * 1_000).rounded()))
    }

    var segmentSourceMap: [String: Segment] {
        Dictionary(uniqueKeysWithValues: segments.indices.map { (segmentID(at: $0), segments[$0]) })
    }

    /// Source-ready transcript for grounded extraction. IDs appear in the
    /// exact notation required by the schema so the model can only cite known
    /// segments that LokalBot can resolve back to audio.
    var evidenceMarkdown: String {
        segments.enumerated().compactMap { index, segment in
            let text = segment.displayText
            guard !text.isEmpty else { return nil }
            return "[\(segmentID(at: index))] [\(Self.stamp(segment.start))] "
                + "\(displaySpeaker(for: segment.speaker)): \(text)"
        }.joined(separator: "\n\n")
    }

    /// Plain spoken text used for language detection and similar NLP passes.
    /// Keep timestamps, speaker labels, and Markdown out of the sample: Apple's
    /// language recognizer can over-weight that short formatting noise.
    var languageDetectionText: String {
        segments.compactMap { seg in
            let text = seg.displayText
            return text.isEmpty ? nil : text
        }.joined(separator: " ")
    }

    /// Consecutive nearby spans from the same speaker become one bounded turn.
    /// A single pathological/legacy span is split at word boundaries as well,
    /// so downstream token-aware chunking always has safe split points.
    func summaryPromptTurns(
        maxCharacters: Int = 1_200,
        maximumGap: TimeInterval = 3
    ) -> [PromptTurn] {
        let characterLimit = max(200, maxCharacters)
        var turns: [PromptTurn] = []

        for segment in segments {
            let text = segment.displayText
            guard !text.isEmpty else { continue }
            for part in Self.summaryTextParts(text, maxCharacters: characterLimit) {
                let canMerge: Bool
                if let previous = turns.last {
                    let sameSpeaker = Self.canonicalSpeakerKey(previous.speaker)
                        == Self.canonicalSpeakerKey(segment.speaker)
                    let gap = segment.start - previous.end
                    canMerge = sameSpeaker
                        && gap <= maximumGap
                        && gap >= -maximumGap
                        && previous.text.count + part.count + 1 <= characterLimit
                } else {
                    canMerge = false
                }

                if canMerge {
                    turns[turns.count - 1].text += " " + part
                    turns[turns.count - 1].end = max(
                        turns[turns.count - 1].end,
                        segment.end)
                } else {
                    turns.append(PromptTurn(
                        start: segment.start,
                        end: segment.end,
                        speaker: segment.speaker,
                        text: part))
                }
            }
        }
        return turns
    }

    var summaryPromptMarkdown: String {
        summaryPromptTurns().map(summaryPromptLine).joined(separator: "\n\n")
    }

    func summaryPromptLine(_ turn: PromptTurn) -> String {
        "**[\(Self.stamp(turn.start))] \(displaySpeaker(for: turn.speaker)):** \(turn.text)"
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

    mutating func setSpeakerAlias(
        _ alias: String?,
        for speaker: String,
        calendarIdentityID: String? = nil
    ) {
        let key = Self.canonicalSpeakerKey(speaker)
        guard !key.isEmpty else { return }
        guard let alias = Self.normalizedAlias(alias ?? ""),
              alias.caseInsensitiveCompare(Self.defaultSpeakerName(for: speaker)) != .orderedSame
        else {
            speakerAliases.removeValue(forKey: key)
            speakerCalendarIdentityIDs.removeValue(forKey: key)
            return
        }
        speakerAliases[key] = alias
        if let identityID = Self.normalizedIdentityID(calendarIdentityID ?? "") {
            speakerCalendarIdentityIDs[key] = identityID
        } else {
            speakerCalendarIdentityIDs.removeValue(forKey: key)
        }
    }

    func speakerAlias(for speaker: String) -> String? {
        speakerAliases[Self.canonicalSpeakerKey(speaker)]
    }

    func calendarIdentityID(for speaker: String) -> String? {
        speakerCalendarIdentityIDs[Self.canonicalSpeakerKey(speaker)]
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

    private static func normalizedIdentityAssignments(
        _ assignments: [String: String]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (speaker, identityID) in assignments {
            let key = canonicalSpeakerKey(speaker)
            guard !key.isEmpty, let identityID = normalizedIdentityID(identityID) else {
                continue
            }
            result[key] = identityID
        }
        return result
    }

    private static func normalizedIdentityID(_ identityID: String) -> String? {
        let trimmed = identityID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    private static func summaryTextParts(
        _ text: String,
        maxCharacters: Int
    ) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return [] }
        var parts: [String] = []
        var current = ""

        func appendCurrent() {
            guard !current.isEmpty else { return }
            parts.append(current)
            current = ""
        }

        for wordSlice in words {
            var word = String(wordSlice)
            while word.count > maxCharacters {
                appendCurrent()
                let splitIndex = word.index(word.startIndex, offsetBy: maxCharacters)
                parts.append(String(word[..<splitIndex]))
                word = String(word[splitIndex...])
            }
            let proposedCount = current.count + (current.isEmpty ? 0 : 1) + word.count
            if proposedCount > maxCharacters { appendCurrent() }
            current += (current.isEmpty ? "" : " ") + word
        }
        appendCurrent()
        return parts
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
