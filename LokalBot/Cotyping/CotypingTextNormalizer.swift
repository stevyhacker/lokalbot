import Foundation

/// Turns raw model output into clean inline ghost text. Ported from Cotabby's
/// `SuggestionTextNormalizer` + `TrailingDuplicationFilter` + `ControlTokenMarkers`
/// + `InsertionSafetyGate` — the backend-agnostic, load-bearing cleanup that
/// makes a small local model's completion safe to show and insert.
///
/// Pure: the same `(raw, request)` always yields the same result, which makes it
/// directly unit-testable without a model.

/// Why a raw completion was reduced to empty ghost text (diagnostics only).
enum CotypingSuppressionReason: String, Sendable, Equatable {
    case emptyGeneration
    case normalizedToEmpty
    case duplicatesTrailingText
    case echoesPrecedingText
    case placeholderText
    case questionContinuation
    case unsafeToInsert
}

struct CotypingNormalizationResult: Equatable, Sendable {
    let text: String
    let suppression: CotypingSuppressionReason?
}

enum CotypingTextNormalizer {
    /// Ghost text only.
    static func normalize(_ raw: String, for request: CotypingRequest) -> String {
        normalizeDetailed(raw, for: request).text
    }

    /// Full pipeline. Mirrors Cotabby's ordering exactly: control-token strip →
    /// think-block strip → prompt/prefix echo strip → leading scaffolding-label
    /// strip → single/multi-line collapse → trailing-duplication → echo-prefix
    /// strip → deterministic space management → safety gate.
    static func normalizeDetailed(_ raw: String, for request: CotypingRequest) -> CotypingNormalizationResult {
        let rawHadContent = !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var normalized = raw.replacingOccurrences(of: "\r", with: "")

        normalized = CotypingControlTokens.sanitize(normalized)
        normalized = stripThinkBlocks(normalized)

        if !request.prompt.isEmpty, normalized.hasPrefix(request.prompt) {
            normalized.removeFirst(request.prompt.count)
            normalized = normalized.trimmingCharacters(in: .controlCharacters.union(.newlines))
        }
        if !request.prefixText.isEmpty, normalized.hasPrefix(request.prefixText) {
            normalized.removeFirst(request.prefixText.count)
        }

        normalized = normalized.trimmingCharacters(in: .controlCharacters.union(.newlines))
        // Drop leading formatting-only newlines before collapsing to one line, so
        // "\ndelicious" is not misread as an empty first line.
        normalized = normalized.trimmingCharacters(in: .newlines)
        normalized = stripLeadingScaffoldingLabels(normalized)
        normalized = stripBenignInlineMarkup(normalized)
        normalized = normalized.trimmingCharacters(in: .newlines)

        if request.isMultiLine {
            if let blankLine = normalized.range(of: "\n\n") {
                normalized = String(normalized[..<blankLine.lowerBound])
            }
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let firstLine = normalized.split(separator: "\n", maxSplits: 1).first {
            normalized = String(firstLine)
        }

        // Mid-word: don't re-type the partial word the caret sits in, and (when
        // strictly inside a word — Cotabby's forceWordContinuation) don't begin
        // with whitespace, so the suggestion continues the current word instead
        // of restarting or space-breaking it. The HTTP backend can't mask the
        // first token like Cotabby's in-process runtime, so it's reproduced here.
        let partialWord = CotypingMidWord.currentPartialWord(in: request.prefixText)
        if partialWord.count >= 2, normalized.count > partialWord.count,
           normalized.lowercased().hasPrefix(partialWord.lowercased()) {
            normalized = String(normalized.dropFirst(partialWord.count))
        }
        if request.forceWordContinuation {
            normalized = String(normalized.drop(while: { $0.isWhitespace }))
        }

        if CotypingTrailingDuplicationFilter.duplicatesTrailingText(
            normalized, trailingText: request.trailingText) {
            return CotypingNormalizationResult(text: "", suppression: .duplicatesTrailingText)
        }

        let beforeEchoStrip = normalized
        normalized = stripEchoPrefix(normalized, precedingText: request.prefixText)
        let collapsedByEcho = !beforeEchoStrip.isEmpty && normalized.isEmpty

        // Space management AFTER echo stripping (which can expose a leading space).
        if request.precedingEndsWithWhitespace {
            normalized = String(normalized.drop(while: { $0.isWhitespace }))
        }

        if beginsNewQuestion(normalized, prefixText: request.prefixText) {
            return CotypingNormalizationResult(text: "", suppression: .questionContinuation)
        }
        normalized = conservativeSingleLineContinuation(normalized, request: request)
        if containsPlaceholderText(normalized) {
            return CotypingNormalizationResult(text: "", suppression: .placeholderText)
        }

        guard CotypingInsertionSafety.isSafeToInsert(normalized) else {
            return CotypingNormalizationResult(
                text: "",
                suppression: suppressionForEmptyResult(
                    collapsedByEcho: collapsedByEcho,
                    rawHadContent: rawHadContent,
                    normalized: normalized))
        }
        return CotypingNormalizationResult(text: normalized, suppression: nil)
    }

    private static func conservativeSingleLineContinuation(
        _ text: String,
        request: CotypingRequest
    ) -> String {
        guard !request.isMultiLine else { return text }
        var working = text
        if let sentenceEnd = firstSentenceBoundaryBeforeNewThought(in: working) {
            working = String(working[...sentenceEnd])
        }
        return limitWords(working, maxWords: max(1, min(30, request.maxWords)))
    }

    private static func firstSentenceBoundaryBeforeNewThought(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "." || character == "!" || character == "?" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next].isWhitespace {
                    return index
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func limitWords(_ text: String, maxWords: Int) -> String {
        guard maxWords > 0 else { return "" }
        var words = 0
        var inWord = false
        var end = text.endIndex
        var truncated = false
        var index = text.startIndex
        while index < text.endIndex {
            let isWord = isSuggestionWordCharacter(text[index])
            if isWord, !inWord {
                words += 1
                if words > maxWords {
                    end = index
                    truncated = true
                    break
                }
                inWord = true
            } else if !isWord {
                inWord = false
            }
            index = text.index(after: index)
        }
        let result = String(text[..<end])
        return truncated
            ? trimmingTrailingLimitBoundary(result)
            : trimmingTrailingWhitespace(result)
    }

    private static func isSuggestionWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "’"
    }

    private static func trimmingTrailingLimitBoundary(_ text: String) -> String {
        var result = trimmingTrailingWhitespace(text)
        while result.last == "." {
            result.removeLast()
            result = trimmingTrailingWhitespace(result)
        }
        return result
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            if text[previous].isWhitespace {
                end = previous
            } else {
                break
            }
        }
        return String(text[..<end])
    }

    private static func containsPlaceholderText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return containsDelimitedPlaceholder(trimmed, open: "[", close: "]")
            || containsDelimitedPlaceholder(trimmed, open: "<", close: ">")
    }

    private static func containsDelimitedPlaceholder(_ text: String, open: Character, close: Character) -> Bool {
        var searchStart = text.startIndex
        while let openIndex = text[searchStart...].firstIndex(of: open),
              let closeIndex = text[text.index(after: openIndex)...].firstIndex(of: close) {
            let contentStart = text.index(after: openIndex)
            let content = text[contentStart..<closeIndex]
            if content.count <= 60, content.contains(where: { $0.isLetter }) {
                return true
            }
            searchStart = text.index(after: closeIndex)
        }
        return false
    }

    private static func stripBenignInlineMarkup(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"</?(?:b|br|code|em|i|kbd|samp|span|strong|u|var)(?:\s+[^>]*)?>"#,
            with: "",
            options: .regularExpression)
    }

    private static func beginsNewQuestion(_ text: String, prefixText: String) -> Bool {
        let trimmedPrefix = prefixText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrefix.hasSuffix("?") { return false }
        let lowered = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
            .lowercased()
        guard !lowered.isEmpty else { return false }
        let questionPrefixes = [
            "what ", "why ", "how ", "when ", "where ", "who ",
            "would you ", "could you ", "can you ", "do you ", "are you ", "is there ",
        ]
        guard questionPrefixes.contains(where: { lowered.hasPrefix($0) }) else { return false }
        return lowered.contains("?")
    }

    private static func suppressionForEmptyResult(
        collapsedByEcho: Bool, rawHadContent: Bool, normalized: String
    ) -> CotypingSuppressionReason {
        if collapsedByEcho { return .echoesPrecedingText }
        if !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .unsafeToInsert }
        return rawHadContent ? .normalizedToEmpty : .emptyGeneration
    }

    private static func stripThinkBlocks(_ text: String) -> String {
        guard text.contains("<think>") else { return text }
        var result = text
        if let complete = result.range(of: "<think>[\\s\\S]*?</think>", options: .regularExpression) {
            result.replaceSubrange(complete, with: "")
        }
        if let dangling = result.range(of: "<think>[\\s\\S]*", options: .regularExpression) {
            result.replaceSubrange(dangling, with: "")
        }
        return result
    }

    /// Strips leading words that repeat the tail of the preceding text. Tries
    /// every word offset; returns "" if the whole suggestion is an echo.
    private static func stripEchoPrefix(_ suggestion: String, precedingText: String) -> String {
        let suggestionWords = suggestion.split(whereSeparator: { $0.isWhitespace })
        guard !suggestionWords.isEmpty else { return suggestion }
        let precedingWords = precedingText.split(whereSeparator: { $0.isWhitespace })
        guard !precedingWords.isEmpty else { return suggestion }

        let maxSearchDepth = min(precedingWords.count, 15)
        var bestOverlap = 0
        for startOffset in 1...maxSearchDepth {
            let tailSlice = precedingWords.suffix(startOffset)
            let headSlice = suggestionWords.prefix(startOffset)
            guard tailSlice.count == headSlice.count else { continue }
            let matches = zip(tailSlice, headSlice).allSatisfy {
                $0.0.caseInsensitiveCompare(String($0.1)) == .orderedSame
            }
            if matches { bestOverlap = startOffset }
        }
        guard bestOverlap > 0 else { return suggestion }
        if bestOverlap >= suggestionWords.count { return "" }
        let lastEchoedWord = suggestionWords[bestOverlap - 1]
        return String(suggestion[lastEchoedWord.endIndex...])
    }

    /// Prompt section-header labels small instruct models tend to parrot.
    private static let scaffoldingLabels: [String] = [
        "Text before the caret:", "Text before caret:",
        "Text after the caret:", "Text after caret:",
        "User Profile Context:", "Your style preferences:",
        "Final instruction:", "Screen context:", "Screen content:",
        "User's clipboard:", "Continuation:", "Application:", "Task:", "App:",
    ]
    private static let labelsByLengthDescending: [String] =
        scaffoldingLabels.sorted { $0.count > $1.count }

    private static func stripLeadingScaffoldingLabels(_ text: String) -> String {
        var working = text
        while true {
            let leading = String(working.drop(while: { $0.isWhitespace }))
            guard let label = labelsByLengthDescending.first(where: {
                leading.range(of: $0, options: [.caseInsensitive, .anchored]) != nil
            }) else { return working }
            working = String(leading.dropFirst(label.count))
        }
    }
}

/// Removes chat/instruct control tokens an instruct model can leak as literal
/// text, and truncates anything after an end-of-turn marker.
enum CotypingControlTokens {
    private static let roleHeaderBlockPattern = "<\\|start_header_id\\|>.*?<\\|end_header_id\\|>"

    static let openingMarkers: [String] = [
        "<|im_start|>", "<start_of_turn>", "<|user|>", "<|assistant|>",
        "<|system|>", "<|start_header_id|>", "<|end_header_id|>", "[INST]", "[/INST]",
    ]
    /// `</s>` is excluded on purpose (it is also the HTML `<s>` closing tag).
    static let stopMarkers: [String] = [
        "<|im_end|>", "<|endoftext|>", "<|end|>", "<end_of_turn>", "<|eot_id|>",
    ]

    static func sanitize(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: roleHeaderBlockPattern, with: "", options: .regularExpression)
        for marker in openingMarkers {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        if let cut = firstStopMarkerLowerBound(in: result) {
            result = String(result[..<cut])
        }
        return result
    }

    private static func firstStopMarkerLowerBound(in text: String) -> String.Index? {
        var earliest: String.Index?
        for marker in stopMarkers {
            guard let range = text.range(of: marker) else { continue }
            earliest = earliest.map { min($0, range.lowerBound) } ?? range.lowerBound
        }
        return earliest
    }
}

/// Decides whether a completion would mostly retype text after the caret.
enum CotypingTrailingDuplicationFilter {
    static let minimumFoldedOverlap = 3

    static func duplicatesTrailingText(_ completion: String, trailingText: String) -> Bool {
        let foldedCompletion = fold(completion)
        guard foldedCompletion.count >= minimumFoldedOverlap else { return false }
        let foldedTrailing = fold(trailingText)
        guard !foldedTrailing.isEmpty else { return false }

        if foldedTrailing.hasPrefix(foldedCompletion) { return true }
        if foldedCompletion.hasPrefix(foldedTrailing), foldedTrailing.count >= minimumFoldedOverlap {
            return true
        }
        let overlap = commonPrefixLength(foldedCompletion, foldedTrailing)
        return overlap >= max(minimumFoldedOverlap, foldedCompletion.count / 2)
    }

    private static func fold(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        var l = lhs.startIndex, r = rhs.startIndex
        while l < lhs.endIndex, r < rhs.endIndex, lhs[l] == rhs[r] {
            count += 1
            l = lhs.index(after: l)
            r = rhs.index(after: r)
        }
        return count
    }
}

/// Rejects completions that are non-empty but would insert junk (control chars,
/// replacement glyphs, whitespace-only).
enum CotypingInsertionSafety {
    static func isSafeToInsert(_ completion: String) -> Bool {
        guard !completion.isEmpty else { return false }
        var sawNonWhitespace = false
        for scalar in completion.unicodeScalars {
            if scalar == "\u{FFFD}" { return false }
            if scalar.value != 0x0A, scalar.value < 0x20 || scalar.value == 0x7F { return false }
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) { sawNonWhitespace = true }
        }
        return sawNonWhitespace
    }
}
