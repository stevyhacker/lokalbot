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

