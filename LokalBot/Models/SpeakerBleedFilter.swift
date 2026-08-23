import Foundation

/// Drops microphone segments that are only the *other* side of the call leaking
/// back in through the speakers.
///
/// LokalBot records the raw input device, so the meeting app's own echo
/// cancellation never applies to our mic track: whenever the user is on
/// speakers rather than headphones, the remote voice lands on both tracks and
/// is transcribed twice — once correctly as `them`, once wrongly as `me`.
///
/// The discriminator is timing, not text alone. Acoustic echo is effectively
/// simultaneous with the sound that caused it, while a person genuinely
/// repeating what was just said speaks *afterwards*. Requiring a large temporal
/// overlap therefore separates the two cases that similar wording alone cannot,
/// which is what keeps a real "yes, exactly what you said" from being deleted.
///
/// Runs before diarization, while speakers are still the raw track labels.
enum SpeakerBleedFilter {

    struct Result {
        var transcript: Transcript
        var removedSegments: Int

        var changed: Bool { removedSegments > 0 }
    }

    /// Fraction of the shorter segment that must overlap in time.
    static let minimumTimeOverlap = 0.5
    /// Fraction of the shorter segment's words that must also appear in the other.
    static let minimumTextSimilarity = 0.8
    /// Below this, wording is too generic to judge ("ja", "genau", "okay").
    static let minimumWordCount = 4

    static func filter(_ transcript: Transcript) -> Result {
        let remote = transcript.segments.filter { canonical($0.speaker) == "them" }
        guard !remote.isEmpty else { return Result(transcript: transcript, removedSegments: 0) }

        var kept: [Transcript.Segment] = []
        var removed = 0
        for segment in transcript.segments {
            if canonical(segment.speaker) == "me",
               remote.contains(where: { isEcho(of: $0, in: segment) }) {
                removed += 1
                continue
            }
            kept.append(segment)
        }
        guard removed > 0 else { return Result(transcript: transcript, removedSegments: 0) }
        var cleaned = transcript
        cleaned.segments = kept
        return Result(transcript: cleaned, removedSegments: removed)
    }

    /// Whether `candidate` (a mic segment) is the speaker bleed of `source`
    /// (a system segment): overlapping in time *and* saying the same thing.
    private static func isEcho(of source: Transcript.Segment,
                               in candidate: Transcript.Segment) -> Bool {
        let candidateWords = words(in: candidate.text)
        let sourceWords = words(in: source.text)
        guard candidateWords.count >= minimumWordCount,
              sourceWords.count >= minimumWordCount,
              timeOverlap(candidate, source) >= minimumTimeOverlap,
              textSimilarity(candidateWords, sourceWords) >= minimumTextSimilarity
        else { return false }
        return true
    }

    /// Overlap as a fraction of the shorter segment, so a brief echo inside a
    /// long remote turn still counts.
    static func timeOverlap(_ lhs: Transcript.Segment, _ rhs: Transcript.Segment) -> Double {
        let overlap = Swift.min(lhs.end, rhs.end) - Swift.max(lhs.start, rhs.start)
        guard overlap > 0 else { return 0 }
        let shorter = Swift.min(lhs.end - lhs.start, rhs.end - rhs.start)
        guard shorter > 0 else { return 0 }
        return Swift.min(1, overlap / shorter)
    }

    /// Multiset word overlap against the shorter side. Echo is rarely a
    /// character-perfect copy — ASR clips the start, adds stray punctuation —
    /// so this tolerates partial capture without matching unrelated sentences.
    static func textSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var remaining: [String: Int] = [:]
        for word in rhs { remaining[word, default: 0] += 1 }
        var shared = 0
        for word in lhs where (remaining[word] ?? 0) > 0 {
            remaining[word]! -= 1
            shared += 1
        }
        return Double(shared) / Double(Swift.min(lhs.count, rhs.count))
    }

    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func canonical(_ speaker: String) -> String {
        speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
