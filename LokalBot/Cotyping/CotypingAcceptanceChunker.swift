import Foundation

/// Pure word/phrase segmentation for suggestion acceptance: what one Tab
/// accepts (`nextWord` / `nextPhrase`), how the accepted chunk is adjusted for
/// insertion (whitespace dedupe, auto-space), and accepted-word accounting.
/// Extracted from the coordinator so the overlay's highlight and the accept
/// path share one segmentation model.
enum CotypingAcceptanceChunker {

    /// First word-like acceptance chunk of `text`, preserving leading
    /// whitespace. Space-less scripts use ICU word segmentation so one accept
    /// advances by a word-sized unit instead of swallowing a whole CJK/Thai run.
    static func nextWord(
        in text: String,
        autoAcceptTrailingPunctuation: Bool = true
    ) -> String {
        guard !text.isEmpty else { return "" }
        var index = text.startIndex
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        let tokenStart = index
        while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }

        if tokenStart < index,
           text[tokenStart].cotypingBeginsSpacelessScriptWord,
           let wordEnd = firstSegmentedWordEnd(in: text, from: tokenStart, notPast: index) {
            index = endOfCJKPunctuationRun(in: text, from: wordEnd, notPast: index)
        } else if tokenStart < index,
                  text[tokenStart].cotypingBindsToPrecedingSpacelessWord
                  || text[tokenStart].cotypingIsCJKOpeningBracket {
            index = endOfCJKPunctuationRun(
                in: text, from: tokenStart, notPast: index, includingOpeners: true)
        }

        if !autoAcceptTrailingPunctuation,
           let wordEnd = wordEndTrimmingTrailingPunctuation(in: text, from: tokenStart, to: index) {
            index = wordEnd
        }

        return String(text[text.startIndex..<index])
    }

    /// Text up to and including the next sentence/clause boundary (or the whole
    /// remaining text when there is none). Mirrors Cotabby's phrase acceptance
    /// granularity: ASCII sentence terminators, newlines, and CJK clause marks;
    /// ASCII commas stay inside the phrase.
    static func nextPhrase(
        in text: String,
        autoAcceptTrailingPunctuation: Bool = true
    ) -> String {
        guard !text.isEmpty else { return "" }
        var accumulated = ""
        var working = text

        while !working.isEmpty {
            let chunk = nextWord(
                in: working,
                autoAcceptTrailingPunctuation: autoAcceptTrailingPunctuation)
            guard !chunk.isEmpty else { break }
            if let newlineIndex = chunk.firstIndex(of: "\n") {
                accumulated += chunk[...newlineIndex]
                return accumulated
            }
            accumulated += chunk
            working = String(working.dropFirst(chunk.count))
            if endsAtPhraseBoundary(accumulated) {
                return accumulated
            }
        }

        return accumulated
    }

    static func insertionChunk(
        forAcceptedChunk chunk: String,
        precedingText: String
    ) -> String {
        guard let lastScalar = precedingText.unicodeScalars.last,
              CharacterSet.whitespaces.contains(lastScalar) else {
            return chunk
        }
        return String(chunk.drop(while: { character in
            character.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
        }))
    }

    static func insertionTextApplyingAutoSpace(
        insertionChunk: String,
        acceptedChunk: String,
        session: CotypingSession,
        addSpaceAfterAccept: Bool
    ) -> String {
        guard addSpaceAfterAccept,
              session.advanced(by: acceptedChunk.count).isExhausted else {
            return insertionChunk
        }
        return insertionChunkAppendingTrailingSpace(insertionChunk)
    }

    static func insertionChunkAppendingTrailingSpace(_ chunk: String) -> String {
        guard let last = chunk.last,
              last.cotypingIsAcceptanceWordCharacter,
              !last.cotypingBeginsSpacelessScriptWord else {
            return chunk
        }
        return chunk + " "
    }

    static func acceptanceChunkConsumingTrailingSpace(
        _ chunk: String,
        remainingText: String
    ) -> String {
        guard let last = chunk.last,
              last.cotypingIsAcceptanceWordCharacter,
              !last.cotypingBeginsSpacelessScriptWord else {
            return chunk
        }
        let remainder = remainingText.dropFirst(chunk.count)
        let trailingSpace = remainder.prefix { $0 == " " || $0 == "\t" }
        return trailingSpace.isEmpty ? chunk : chunk + trailingSpace
    }

    static func acceptedWordCount(in text: String) -> Int {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .filter { token in
                token.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            }
            .count
    }

    // MARK: - Private

    private static func firstSegmentedWordEnd(
        in text: String,
        from start: String.Index,
        notPast limit: String.Index
    ) -> String.Index? {
        var wordEnd: String.Index?
        text.enumerateSubstrings(
            in: start..<limit,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, stop in
            wordEnd = range.upperBound
            stop = true
        }
        guard let wordEnd, wordEnd > start else { return nil }
        return min(wordEnd, limit)
    }

    private static func endOfCJKPunctuationRun(
        in text: String,
        from start: String.Index,
        notPast limit: String.Index,
        includingOpeners: Bool = false
    ) -> String.Index {
        var cursor = start
        while cursor < limit {
            let character = text[cursor]
            guard character.cotypingBindsToPrecedingSpacelessWord
                    || (includingOpeners && character.cotypingIsCJKOpeningBracket) else {
                break
            }
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    private static func endsAtPhraseBoundary(_ text: String) -> Bool {
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous] == " " || text[previous] == "\t" || text[previous].cotypingIsPhraseClosingPunctuation {
                index = previous
            } else {
                break
            }
        }
        guard index > text.startIndex else { return false }
        let previous = text.index(before: index)
        if text[previous].cotypingIsPhraseClauseBoundary { return true }
        guard text[previous].cotypingIsPhraseSentenceTerminator else { return false }
        if text[previous] == "." {
            return isTerminalPeriod(in: text, at: previous)
        }
        return true
    }

    private static func wordEndTrimmingTrailingPunctuation(
        in text: String,
        from tokenStart: String.Index,
        to tokenEnd: String.Index
    ) -> String.Index? {
        var lastWordCharacterEnd: String.Index?
        var cursor = tokenStart
        while cursor < tokenEnd {
            if text[cursor].cotypingIsAcceptanceWordCharacter {
                lastWordCharacterEnd = text.index(after: cursor)
            }
            cursor = text.index(after: cursor)
        }
        guard let wordEnd = lastWordCharacterEnd, wordEnd < tokenEnd else {
            return nil
        }
        return wordEnd
    }

    private static func isTerminalPeriod(in text: String, at periodIndex: String.Index) -> Bool {
        guard periodIndex > text.startIndex else { return true }
        let beforeIndex = text.index(before: periodIndex)
        let beforeChar = text[beforeIndex]
        if beforeChar.isNumber { return false }
        if beforeChar.isLetter {
            let priorIsLetter = beforeIndex > text.startIndex
                && text[text.index(before: beforeIndex)].isLetter
            if !priorIsLetter { return false }
            if terminalPeriodAbbreviations.contains(
                trailingLetters(in: text, endingBefore: periodIndex).lowercased()) {
                return false
            }
        }
        return true
    }

    private static let terminalPeriodAbbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "vs", "eg", "ie", "etc", "no", "fig", "approx", "inc", "ltd"
    ]

    private static func trailingLetters(in text: String, endingBefore index: String.Index) -> String {
        var letters: [Character] = []
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous].isLetter else { break }
            letters.append(text[previous])
            cursor = previous
        }
        return String(letters.reversed())
    }
}

extension Character {
    var cotypingBeginsSpacelessScriptWord: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana + Katakana
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xAC00...0xD7A3,   // Hangul syllables
             0x1100...0x11FF,   // Hangul Jamo
             0x0E00...0x0E7F,   // Thai
             0x0E80...0x0EFF,   // Lao
             0x1780...0x17FF,   // Khmer
             0x1000...0x109F,   // Myanmar
             0x20000...0x2A6DF, // CJK Unified Ideographs Extension B
             0x30000...0x3134F: // CJK Unified Ideographs Extension G
            return true
        default:
            return false
        }
    }

    var cotypingBindsToPrecedingSpacelessWord: Bool {
        cotypingIsCJKSentenceTerminator
            || cotypingIsPhraseClauseBoundary
            || cotypingIsCJKClosingPunctuation
    }

    var cotypingIsCJKSentenceTerminator: Bool {
        self == "\u{3002}" || self == "\u{FF01}" || self == "\u{FF1F}" || self == "\u{FF61}"
    }

    var cotypingIsCJKClosingPunctuation: Bool {
        self == "\u{300D}" || self == "\u{300F}" || self == "\u{FF09}"
            || self == "\u{3011}" || self == "\u{3009}" || self == "\u{300B}" || self == "\u{FF63}"
    }

    var cotypingIsCJKOpeningBracket: Bool {
        self == "\u{300C}" || self == "\u{300E}" || self == "\u{FF08}"
            || self == "\u{3010}" || self == "\u{3008}" || self == "\u{300A}" || self == "\u{FF62}"
    }

    var cotypingIsPhraseSentenceTerminator: Bool {
        self == "." || self == "!" || self == "?" || cotypingIsCJKSentenceTerminator
    }

    var cotypingIsPhraseClauseBoundary: Bool {
        self == "\u{3001}" || self == "\u{FF0C}" || self == "\u{FF64}"
    }

    var cotypingIsPhraseClosingPunctuation: Bool {
        self == "\"" || self == "'" || self == "\u{201D}" || self == "\u{2019}"
            || self == ")" || self == "]" || self == "}"
            || cotypingIsCJKClosingPunctuation
    }

    var cotypingIsAcceptanceWordCharacter: Bool {
        isLetter || isNumber
    }
}
