import Foundation

/// Removes only objectively pathological ASR repetition. Normal conversational
/// emphasis is left intact: word/phrase collapse is gated by both an impossible
/// speaking rate and a long repeated cycle.
enum TranscriptSanitizer {
    struct Result {
        var transcript: Transcript
        var changedSegments: Int
        var removedWords: Int
        var removedCharacters: Int

        var changed: Bool { changedSegments > 0 }
    }

    private struct Word: Equatable {
        var original: String
        var normalized: String
    }

    private struct Loop {
        var period: Int
        var repetitions: Int

        var span: Int { period * repetitions }
    }

    static func sanitize(_ transcript: Transcript) -> Result {
        var cleaned = transcript
        var changedSegments = 0
        var removedWords = 0
        var removedCharacters = 0

        for index in cleaned.segments.indices {
            let segment = cleaned.segments[index]
            let original = segment.displayText
            guard !original.isEmpty else { continue }
            let characterCleaned = collapseExtremeCharacterRuns(in: original)
            let originalWords = words(in: characterCleaned)
            var finalText = characterCleaned

            let duration = max(0.25, segment.end - segment.start)
            let wordsPerSecond = Double(originalWords.count) / duration
            if originalWords.count >= 80, wordsPerSecond >= 12 {
                let collapsed = collapseRepeatedCycles(originalWords)
                if collapsed.count < originalWords.count {
                    finalText = collapsed.map(\.original).joined(separator: " ")
                    if let punctuation = terminalPunctuation(in: characterCleaned),
                       finalText.last != punctuation {
                        finalText.append(punctuation)
                    }
                    removedWords += originalWords.count - collapsed.count
                }
            }

            finalText = Transcript.normalizedText(finalText)
            guard finalText != original else { continue }
            removedCharacters += max(0, original.count - finalText.count)
            cleaned.segments[index].text = finalText
            changedSegments += 1
        }

        return Result(
            transcript: cleaned,
            changedSegments: changedSegments,
            removedWords: removedWords,
            removedCharacters: removedCharacters)
    }

    private static func words(in text: String) -> [Word] {
        text.split(whereSeparator: { character in
            !character.isLetter && !character.isNumber
                && character != "'" && character != "’"
        }).map {
            let original = String($0)
            return Word(original: original, normalized: original.lowercased())
        }
    }

    private static func collapseRepeatedCycles(_ input: [Word]) -> [Word] {
        guard input.count >= 8 else { return input }
        var output: [Word] = []
        var index = 0

        while index < input.count {
            if let loop = longestLoop(in: input, startingAt: index) {
                let keptWords = loop.period * 2
                output.append(contentsOf: input[index..<(index + keptWords)])
                index += loop.span
            } else {
                output.append(input[index])
                index += 1
            }
        }
        return output
    }

    private static func longestLoop(in words: [Word], startingAt start: Int) -> Loop? {
        let maximumPeriod = min(32, (words.count - start) / 4)
        guard maximumPeriod > 0 else { return nil }
        var best: Loop?

        for period in 1...maximumPeriod {
            var repetitions = 1
            while start + (repetitions + 1) * period <= words.count,
                  groupsMatch(words, first: start,
                              second: start + repetitions * period,
                              count: period) {
                repetitions += 1
            }

            let redundantWords = period * max(0, repetitions - 2)
            let isLongRun = period == 1 && repetitions >= 8
            guard repetitions >= 4, redundantWords >= 24 || isLongRun else { continue }
            let candidate = Loop(period: period, repetitions: repetitions)
            if best == nil
                || candidate.span > best!.span
                || candidate.span == best!.span && candidate.period < best!.period {
                best = candidate
            }
        }
        return best
    }

    private static func groupsMatch(
        _ words: [Word],
        first: Int,
        second: Int,
        count: Int
    ) -> Bool {
        for offset in 0..<count
        where words[first + offset].normalized != words[second + offset].normalized {
            return false
        }
        return true
    }

    /// Eight identical characters cannot add meaning to a transcript. Keeping
    /// three retains audible emphasis ("ummm", "sooo") without allowing one
    /// hallucinated token to dominate a prompt.
    private static func collapseExtremeCharacterRuns(in text: String) -> String {
        guard !text.isEmpty else { return text }
        var output = ""
        var run: [Character] = []

        func appendRun() {
            guard let character = run.first else { return }
            let shouldCollapse = run.count >= 8
                && (character.isLetter || character.isNumber || character.isPunctuation)
            let retained = shouldCollapse ? Array(run.prefix(3)) : run
            output.append(contentsOf: retained)
            run.removeAll(keepingCapacity: true)
        }

        for character in text {
            if let first = run.first,
               String(first).lowercased() != String(character).lowercased() {
                appendRun()
            }
            run.append(character)
        }
        appendRun()
        return output
    }

    private static func terminalPunctuation(in text: String) -> Character? {
        guard let final = text.last(where: { !$0.isWhitespace }),
              ".!?…".contains(final) else { return nil }
        return final
    }
}
