import Foundation

/// Removes the *other* side of the call where it leaks back into the
/// microphone through the speakers.
///
/// LokalBot records the raw input device, so the meeting app's own echo
/// cancellation never applies to our mic track: whenever the user is on
/// speakers rather than headphones, the remote voice lands on both tracks and
/// is transcribed twice — once correctly as `them`, once wrongly as `me`.
///
/// The discriminator is timing, not text alone. Acoustic echo is effectively
/// simultaneous with the sound that caused it, while a person genuinely
/// repeating what was just said speaks *afterwards*. Requiring temporal
/// overlap therefore separates the two cases that similar wording alone
/// cannot, which is what keeps a real "yes, exactly what you said" alive.
///
/// Echo rarely fills a whole mic segment, though. The two tracks are
/// transcribed independently, so their segment boundaries fall in different
/// places and a single mic segment routinely carries an echoed opening
/// followed by the user's own words — measured on a real 49-minute meeting,
/// mixed segments outnumbered pure ones. Dropping whole segments therefore
/// either loses real speech or keeps the echo. This filter instead locates the
/// longest run of words the remote side said at the same moment and trims just
/// that run when it sits at a segment edge; a segment left with nothing is
/// dropped, which is the pure-echo case falling out of the same rule.
///
/// Runs before diarization, while speakers are still the raw track labels.
enum SpeakerBleedFilter {

    struct Result {
        var transcript: Transcript
        var removedSegments: Int
        var trimmedSegments: Int
        var removedWords: Int

        var changed: Bool { removedSegments > 0 || trimmedSegments > 0 }
    }

    /// Fraction of the shorter segment that must overlap in time before the
    /// two are compared at all. Lower than a "same utterance" test would need
    /// because a long remote turn overlaps only part of a short mic segment.
    static let minimumTimeOverlap = 0.3
    /// Words a shared run needs before it counts as echo rather than as two
    /// people reaching for the same common phrase.
    static let minimumRunLength = 3
    /// The same bar for scripts written without spaces, where a token is one
    /// character rather than one word. Chinese averages well under two
    /// characters per word, so this is about as much language as
    /// `minimumRunLength` words are — three characters would be a single word
    /// and would collide by chance far too often.
    static let minimumIdeographicRunLength = 6
    /// A segment trimmed below this is echo throughout and is dropped.
    static let minimumRemainder = 3
    /// Echo can sit at both ends of one segment, and ASR splits a run around a
    /// misheard word; a few passes catch those without unbounded chewing.
    static let maximumTrimPasses = 3
    /// Stray words the ASR tacks onto an echo ("ja", a clipped article) may
    /// precede or follow the run and are trimmed with it.
    static let edgeSlack = 1

    static func filter(_ transcript: Transcript) -> Result {
        let remote = transcript.segments.filter { canonical($0.speaker) == "them" }
        guard !remote.isEmpty else {
            return Result(transcript: transcript, removedSegments: 0,
                          trimmedSegments: 0, removedWords: 0)
        }

        var kept: [Transcript.Segment] = []
        var removed = 0
        var trimmed = 0
        var removedWords = 0

        for segment in transcript.segments {
            guard canonical(segment.speaker) == "me" else {
                kept.append(segment)
                continue
            }
            let partners = remote.filter { timeOverlap(segment, $0) >= minimumTimeOverlap }
            guard !partners.isEmpty else {
                kept.append(segment)
                continue
            }
            let outcome = stripEcho(from: segment.text,
                                    heardIn: partners.map(\.text))
            removedWords += outcome.removedWords
            switch outcome.remainder {
            case .none:
                removed += 1
            case .unchanged:
                kept.append(segment)
            case .trimmed(let text):
                var cleaned = segment
                cleaned.text = text
                kept.append(cleaned)
                trimmed += 1
            }
        }

        guard removed > 0 || trimmed > 0 else {
            return Result(transcript: transcript, removedSegments: 0,
                          trimmedSegments: 0, removedWords: 0)
        }
        var cleaned = transcript
        cleaned.segments = kept
        return Result(transcript: cleaned, removedSegments: removed,
                      trimmedSegments: trimmed, removedWords: removedWords)
    }

    // MARK: - Trimming

    enum Remainder: Equatable {
        /// Nothing of the segment survives — it was echo throughout.
        case none
        /// No echo run found at an edge; the segment stands as recorded.
        case unchanged
        /// What is left after the echoed edges were cut away.
        case trimmed(String)
    }

    struct StripOutcome: Equatable {
        var remainder: Remainder
        var removedWords: Int
    }

    /// Cuts the runs of `text` that one of `sources` said at the same time.
    /// Pure, so the edge rules are testable without segments or timings.
    static func stripEcho(from text: String, heardIn sources: [String]) -> StripOutcome {
        let original = tokens(in: text)
        guard !original.isEmpty else {
            return StripOutcome(remainder: .unchanged, removedWords: 0)
        }
        let sourceWords = sources.map { tokens(in: $0).map(\.word) }
        var current = original
        var removedWords = 0

        for _ in 0..<maximumTrimPasses {
            let words = current.map(\.word)
            var best = SharedRun(length: 0, start: 0, end: 0)
            for source in sourceWords {
                let run = longestSharedRun(words, source)
                if run.length > best.length { best = run }
            }
            guard best.length >= requiredRunLength(for: current, run: best) else { break }
            // Only edge runs are cut. An echo in the middle of a segment would
            // mean the user spoke both before and after it, and stitching the
            // two halves together would invent a sentence neither said.
            if best.start <= edgeSlack {
                current = Array(current[best.end...])
            } else if best.end >= current.count - edgeSlack {
                current = Array(current[..<best.start])
            } else {
                break
            }
            removedWords += best.length
            if current.isEmpty { break }
        }

        if current.count == original.count {
            return StripOutcome(remainder: .unchanged, removedWords: 0)
        }
        guard current.count >= minimumRemainder,
              let first = current.first, let last = current.last else {
            return StripOutcome(remainder: .none, removedWords: removedWords)
        }
        let slice = String(text[first.range.lowerBound..<last.range.upperBound])
        return StripOutcome(remainder: .trimmed(Transcript.normalizedText(slice)),
                            removedWords: removedWords)
    }

    struct SharedRun: Equatable {
        var length: Int
        /// Index of the first shared word in the left-hand side.
        var start: Int
        /// One past the last shared word in the left-hand side.
        var end: Int
    }

    /// Longest run of consecutive words both sides share, comparing words
    /// loosely (see `wordsMatch`). Positions refer to `lhs`.
    static func longestSharedRun(_ lhs: [String], _ rhs: [String]) -> SharedRun {
        var best = SharedRun(length: 0, start: 0, end: 0)
        guard !lhs.isEmpty, !rhs.isEmpty else { return best }
        var previous = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            var current = [Int](repeating: 0, count: rhs.count + 1)
            for j in 1...rhs.count where wordsMatch(lhs[i - 1], rhs[j - 1]) {
                current[j] = previous[j - 1] + 1
                if current[j] > best.length {
                    best = SharedRun(length: current[j], start: i - current[j], end: i)
                }
            }
            previous = current
        }
        return best
    }

    /// How long `run` must be to count as echo: runs written in an unspaced
    /// script are measured in characters, everything else in words. Decided by
    /// majority so a run that mixes the two (a Latin product name inside a
    /// Chinese sentence) still uses the threshold of the script it mostly is.
    static func requiredRunLength(for tokens: [Token], run: SharedRun) -> Int {
        guard run.length > 0, run.end <= tokens.count else { return minimumRunLength }
        let ideographic = tokens[run.start..<run.end].reduce(into: 0) { count, token in
            if token.isIdeographic { count += 1 }
        }
        return ideographic * 2 >= run.length ? minimumIdeographicRunLength : minimumRunLength
    }

    /// Whether two words are the same word. The tracks are transcribed by two
    /// independent passes over different audio, so the same spoken word comes
    /// back slightly different — "Wim"/"Bim", "reinbasta"/"reinbasteln" — and
    /// exact equality misses most real echo. One edit is allowed from three
    /// characters up, where a single letter no longer changes the word.
    static func wordsMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let left = Array(lhs), right = Array(rhs)
        guard Swift.min(left.count, right.count) >= 3,
              abs(left.count - right.count) <= 1 else { return false }
        return differsByAtMostOneEdit(left, right)
    }

    /// Single-edit check by walking both sides once, rather than a full edit
    /// distance we would immediately threshold anyway.
    private static func differsByAtMostOneEdit(_ lhs: [Character], _ rhs: [Character]) -> Bool {
        let (shorter, longer) = lhs.count <= rhs.count ? (lhs, rhs) : (rhs, lhs)
        var i = 0, j = 0
        var edited = false
        while i < shorter.count, j < longer.count {
            if shorter[i] == longer[j] {
                i += 1; j += 1
                continue
            }
            if edited { return false }
            edited = true
            if shorter.count == longer.count { i += 1 }
            j += 1
        }
        return true
    }

    // MARK: - Tokens, timing

    struct Token: Equatable {
        var word: String
        var range: Range<String.Index>
        /// Set for tokens that are a single character of an unspaced script.
        var isIdeographic = false
    }

    /// Chinese and Japanese are written without spaces between words. Whether a
    /// character belongs to one of those scripts decides how the text is cut
    /// into tokens — Korean is deliberately absent, because Hangul is spaced
    /// and tokenizes like a Latin script.
    static func isIdeographic(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF,    // Hiragana and Katakana
             0x3400...0x4DBF,    // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,    // CJK Unified Ideographs
             0xF900...0xFAFF,    // CJK Compatibility Ideographs
             0x20000...0x2FA1F:  // Extension B and beyond
            return true
        default:
            return false
        }
    }

    /// Words with their place in the original text, so a trimmed segment can be
    /// sliced out of it and keep its punctuation and capitalization.
    static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isLetter || text[index].isNumber else {
                index = text.index(after: index)
                continue
            }
            // An unspaced script has no word boundaries to split on, so a whole
            // Mandarin sentence would arrive as one token and no run could ever
            // reach `minimumRunLength`. Emitting each character separately makes
            // the run search a character n-gram match, which is the comparison
            // those scripts need.
            if isIdeographic(text[index]) {
                let next = text.index(after: index)
                tokens.append(Token(word: String(text[index]).lowercased(),
                                    range: index..<next,
                                    isIdeographic: true))
                index = next
                continue
            }
            let start = index
            while index < text.endIndex,
                  text[index].isLetter || text[index].isNumber,
                  !isIdeographic(text[index]) {
                index = text.index(after: index)
            }
            tokens.append(Token(word: text[start..<index].lowercased(), range: start..<index))
        }
        return tokens
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

    static func words(in text: String) -> [String] {
        tokens(in: text).map(\.word)
    }

    private static func canonical(_ speaker: String) -> String {
        speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
