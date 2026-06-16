import Foundation

enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable {
    case auto
    case en
    case de
    case es
    case fr
    case it
    case nl
    case pt
    case pl
    case sv
    case da
    case no
    case tr
    case ru
    case zh
    case yue
    case ja
    case ko
    case ar
    case hi
    case th
    case vi

    var id: String { rawValue }

    var code: String? {
        switch self {
        case .auto: nil
        default: rawValue
        }
    }

    var displayName: String {
        switch self {
        case .auto: "Auto-detect"
        case .en: "English"
        case .de: "German"
        case .es: "Spanish"
        case .fr: "French"
        case .it: "Italian"
        case .nl: "Dutch"
        case .pt: "Portuguese"
        case .pl: "Polish"
        case .sv: "Swedish"
        case .da: "Danish"
        case .no: "Norwegian"
        case .tr: "Turkish"
        case .ru: "Russian"
        case .zh: "Chinese (Mandarin)"
        case .yue: "Chinese (Cantonese)"
        case .ja: "Japanese"
        case .ko: "Korean"
        case .ar: "Arabic"
        case .hi: "Hindi"
        case .th: "Thai"
        case .vi: "Vietnamese"
        }
    }

    static func fromLegacyHint(_ hint: String) -> TranscriptionLanguage {
        let normalized = hint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .auto }
        return Self(rawValue: normalized) ?? .auto
    }
}
