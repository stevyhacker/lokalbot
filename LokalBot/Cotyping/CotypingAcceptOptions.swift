import CoreGraphics
import Foundation

/// How much the primary accept key takes per press. The full-accept key always
/// takes the whole remaining tail, so this has no "whole" case (that would
/// duplicate it) — mirrors Cotabby's `AcceptanceGranularity`.
enum CotypingAcceptGranularity: String, Codable, CaseIterable, Identifiable, Sendable {
    case word
    case phrase

    var id: String { rawValue }
    var label: String {
        switch self {
        case .word: "One word"
        case .phrase: "One phrase"
        }
    }
}

/// The primary accept key (take the next word/phrase). Curated safe choices
/// rather than a free record-shortcut UI.
enum CotypingAcceptKey: Int, Codable, CaseIterable, Identifiable, Sendable {
    case tab = 48
    case rightArrow = 124

    var id: Int { rawValue }
    var keyCode: CGKeyCode { CGKeyCode(rawValue) }
    var label: String {
        switch self {
        case .tab: "Tab"
        case .rightArrow: "Right Arrow"
        }
    }
}

/// The full-accept key (take the entire remaining suggestion), or off.
enum CotypingFullAcceptKey: Int, Codable, CaseIterable, Identifiable, Sendable {
    case backtick = 50
    case rightArrow = 124
    case off = -1

    var id: Int { rawValue }
    var keyCode: CGKeyCode? { self == .off ? nil : CGKeyCode(rawValue) }
    var label: String {
        switch self {
        case .backtick: "Backtick `"
        case .rightArrow: "Right Arrow"
        case .off: "Off"
        }
    }
}

/// Which accept key fired — the next chunk (word/phrase) or the whole tail.
enum CotypingAcceptScope: Sendable {
    case chunk
    case whole
}
