import Foundation

enum LanguageCode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case en
    case zh
    case zhHant = "zh-Hant"
    case yue
    case ja
    case ko
    case es
    case fr
    case de
    case pt
    case ptPT = "pt-PT"
    case ru
    case ar
    case hi
    case it
    case nl
    case tr
    case pl
    case sv
    case da
    case no
    case nn
    case th
    case vi

    var id: String { rawValue }

    static let transcriptionSupported: [LanguageCode] = [
        .en, .de, .es, .fr, .it, .nl, .pt, .pl, .sv, .da, .no, .tr,
        .ru, .zh, .yue, .ja, .ko, .ar, .hi, .th, .vi,
    ]

    static let summaryPresets: [LanguageCode] = [
        .en, .zh, .zhHant, .yue, .ja, .ko, .es, .fr, .de, .pt, .ptPT,
        .ru, .ar, .hi, .it, .nl, .tr, .pl, .sv, .da, .no, .nn, .th, .vi,
    ]

    private static let summaryDisplayNames: [LanguageCode: String] = [
        .en: "English",
        .zh: "Simplified Chinese (Mandarin)",
        .zhHant: "Traditional Chinese (Mandarin)",
        .yue: "Cantonese",
        .ja: "Japanese",
        .ko: "Korean",
        .es: "Spanish",
        .fr: "French",
        .de: "German",
        .pt: "Portuguese (Brazil)",
        .ptPT: "Portuguese (Portugal)",
        .ru: "Russian",
        .ar: "Arabic",
        .hi: "Hindi",
        .it: "Italian",
        .nl: "Dutch",
        .tr: "Turkish",
        .pl: "Polish",
        .sv: "Swedish",
        .da: "Danish",
        .no: "Norwegian (Bokmål)",
        .nn: "Norwegian (Nynorsk)",
        .th: "Thai",
        .vi: "Vietnamese",
    ]

    var summaryDisplayName: String {
        Self.summaryDisplayNames[self] ?? rawValue
    }

    var transcriptionDisplayName: String {
        switch self {
        case .pt: return "Portuguese"
        case .no: return "Norwegian"
        case .zh: return "Chinese (Mandarin)"
        case .yue: return "Chinese (Cantonese)"
        default: return summaryDisplayName
        }
    }
}
