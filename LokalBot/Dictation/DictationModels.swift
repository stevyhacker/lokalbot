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
