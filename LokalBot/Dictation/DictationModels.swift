import CoreGraphics
import Foundation

enum DictationTriggerMode: String, Codable, CaseIterable, Identifiable {
    case pushToTalk = "Push to talk"
    case toggle = "Toggle"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pushToTalk: "Push to talk"
        case .toggle: "Toggle"
        }
    }
}

enum DictationOutputMode: String, Codable, CaseIterable, Identifiable {
    case pasteIntoFocusedApp = "Paste into focused app"
    case copyToClipboard = "Copy to clipboard"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pasteIntoFocusedApp: "Paste into focused app"
        case .copyToClipboard: "Copy to clipboard"
        }
    }
}

struct DictationLiveTranscript: Equatable, Sendable {
    var committed: String = ""
    var tentative: String = ""

    var isEmpty: Bool {
        committed.isEmpty && tentative.isEmpty
    }

    var displayText: String {
        [committed, tentative]
            .filter { !$0.isEmpty }
            .joined(separator: committed.isEmpty || tentative.isEmpty ? "" : " ")
    }

    static func preview(from text: String) -> Self {
        let normalized = Transcript.normalizedText(text)
        guard !normalized.isEmpty else { return .init() }

        if let last = normalized.last, ".!?".contains(last) {
            return .init(committed: normalized, tentative: "")
        }

        if let boundary = lastSentenceBoundary(in: normalized) {
            let committed = normalized[..<normalized.index(after: boundary)]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tentative = normalized[normalized.index(after: boundary)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(committed: committed, tentative: tentative)
        }

        let words = normalized.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > 8 else {
            return .init(committed: "", tentative: normalized)
        }
        let committed = words.dropLast(6).joined(separator: " ")
        let tentative = words.suffix(6).joined(separator: " ")
        return .init(committed: committed, tentative: tentative)
    }

    private static func lastSentenceBoundary(in text: String) -> String.Index? {
        text.indices
            .filter { ".!?".contains(text[$0]) }
            .last
    }
}

struct DictationPreviewAudioRange: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
}

/// Pure planning for the rolling dictation preview. Each pass starts slightly
/// before the last completed pass so the ASR model hears enough context to
/// finish a word that crossed the boundary, without decoding the whole growing
/// recording again.
enum DictationPreviewWindowPlanner {
    static let defaultOverlapSeconds: TimeInterval = 2.5

    static func range(previousEnd: TimeInterval,
                      currentEnd: TimeInterval) -> DictationPreviewAudioRange? {
        range(previousEnd: previousEnd,
              currentEnd: currentEnd,
              overlapSeconds: defaultOverlapSeconds)
    }

    static func range(previousEnd: TimeInterval,
                      currentEnd: TimeInterval,
                      overlapSeconds: TimeInterval) -> DictationPreviewAudioRange? {
        let previous = max(0, previousEnd)
        guard currentEnd > previous else { return nil }
        return .init(
            start: max(0, previous - max(0, overlapSeconds)),
            end: currentEnd
        )
    }
}

/// Deterministically joins overlapping ASR windows. The newest window replaces
/// the matched suffix so revised capitalization or punctuation at the boundary
/// wins, while a window with no trustworthy two-word overlap is appended rather
/// than risking the loss of already-visible speech.
enum DictationPreviewTextStitcher {
    static func stitch(previous: String,
                       incoming: String,
                       maximumOverlapWords: Int = 32,
                       minimumOverlapWords: Int = 2) -> String {
        let oldText = Transcript.normalizedText(previous)
        let newText = Transcript.normalizedText(incoming)
        guard !oldText.isEmpty else { return newText }
        guard !newText.isEmpty else { return oldText }

        let oldWords = oldText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let newWords = newText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let upperBound = min(max(0, maximumOverlapWords), oldWords.count, newWords.count)
        let lowerBound = max(1, minimumOverlapWords)

        if upperBound >= lowerBound {
            for count in stride(from: upperBound, through: lowerBound, by: -1) {
                let oldStart = oldWords.count - count
                let matches = (0..<count).allSatisfy { offset in
                    wordKey(oldWords[oldStart + offset]) == wordKey(newWords[offset])
                        && !wordKey(newWords[offset]).isEmpty
                }
                if matches {
                    return (oldWords.dropLast(count) + newWords).joined(separator: " ")
                }
            }
        }

        return oldText + " " + newText
    }

    private static func wordKey(_ word: String) -> String {
        word
            .folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

struct DictationShortcut: Equatable, Sendable {
    var keyCode: CGKeyCode
    var modifiers: CGEventFlags

    static let handyDefault = DictationShortcut(keyCode: 49, modifiers: .maskAlternate)
    static let label = "⌥ Space"

    func matches(_ event: CGEvent) -> Bool {
        matchesKeyCode(event) && event.flags.dictationRelevantModifiers == modifiers
    }

    func matchesKeyCode(_ event: CGEvent) -> Bool {
        CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == keyCode
    }
}

private extension CGEventFlags {
    var dictationRelevantModifiers: CGEventFlags {
        intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
    }
}
