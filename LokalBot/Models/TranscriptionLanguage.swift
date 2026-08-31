import Foundation

enum TranscriptionLanguage: RawRepresentable, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case auto
    case language(LanguageCode)

    static let allCases: [TranscriptionLanguage] = [.auto]
        + LanguageCode.transcriptionSupported.map { .language($0) }

    static let de: TranscriptionLanguage = .language(.de)
    static let es: TranscriptionLanguage = .language(.es)
    static let fr: TranscriptionLanguage = .language(.fr)

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .auto: return "auto"
        case .language(let code): return code.rawValue
        }
    }

    init?(rawValue: String) {
        if rawValue == "auto" {
            self = .auto
        } else if let code = LanguageCode(rawValue: rawValue),
                  LanguageCode.transcriptionSupported.contains(code) {
            self = .language(code)
        } else {
            return nil
        }
    }

    var code: String? {
        switch self {
        case .auto: return nil
        case .language(let code): return code.rawValue
        }
    }

    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .language(let code): return code.transcriptionDisplayName
        }
    }

    static func fromLegacyHint(_ hint: String) -> TranscriptionLanguage {
        let normalized = hint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .auto }
        return Self(rawValue: normalized) ?? .auto
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let language = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown transcription language: \(rawValue)"
            )
        }
        self = language
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
