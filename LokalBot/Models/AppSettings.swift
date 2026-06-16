import Foundation

struct AppSettings: Codable {
    enum AutoRecordMode: String, Codable, CaseIterable, Identifiable {
        case automatic = "Record automatically"
        case ask = "Ask via notification"
        case manual = "Never auto-record"
        var id: String { rawValue }
    }

    enum SummarizerBackend: String, Codable, CaseIterable, Identifiable {
        case builtIn = "Built-in (no setup)"
        case ollama = "Ollama"
        case openAICompatible = "OpenAI-compatible server"
        var id: String { rawValue }
    }

    var autoRecordMode: AutoRecordMode = .automatic
    /// Seconds the mic must be released before a meeting counts as ended.
    var stopDebounceSeconds: TimeInterval = 60

    // MARK: Models (M2)

    var transcriptionModel: TranscriptionModelChoice = .parakeetV3
    var transcriptionLanguage: TranscriptionLanguage = .auto
    var autoTranscribe: Bool = true
    var autoSummarize: Bool = true

    /// M4: app/window activity sampling.
    var trackingEnabled: Bool = true

    /// M6: embedding-based semantic search (nomic-embed, downloaded when enabled).
    var semanticSearchEnabled: Bool = false

    // M5: screenshots + OCR
    var screenshotsEnabled: Bool = true
    var screenshotIntervalMinutes: Double = 3
    var retentionDays: Int = 14
    /// Comma-separated app-name substrings that are never captured;
    /// their time shows as "Private" in the timeline.
    var excludedApps: String = "1Password, Keychain Access, Bitwarden, KeePassXC"
    var excludedAppList: [String] {
        excludedApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var summarizerBackend: SummarizerBackend = .builtIn
    var builtInModelID: String = ModelCatalog.bundledID
    var ollamaBaseURL: String = "http://localhost:11434"
    var ollamaModel: String = ""
    var openAIBaseURL: String = "http://localhost:1234/v1"
    var openAIModel: String = ""
    var openAIAPIKey: String {
        get {
            KeychainSecrets.string(account: "openai-compatible-api-key") ?? ""
        }
        set {
            KeychainSecrets.setString(newValue, account: "openai-compatible-api-key")
        }
    }

    private static let key = "lokalbot.settings"

    private enum CodingKeys: String, CodingKey {
        case autoRecordMode
        case stopDebounceSeconds
        case transcriptionModel
        case transcriptionLanguage
        case languageHint // legacy key used by builds before typed language selection
        case autoTranscribe
        case autoSummarize
        case trackingEnabled
        case semanticSearchEnabled
        case screenshotsEnabled
        case screenshotIntervalMinutes
        case retentionDays
        case excludedApps
        case summarizerBackend
        case builtInModelID
        case ollamaBaseURL
        case ollamaModel
        case openAIBaseURL
        case openAIModel
    }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    // Tolerant decoding: settings saved by an older build (fewer keys) keep
    // working instead of silently resetting everything to defaults.
    init() {}

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(autoRecordMode, forKey: .autoRecordMode)
        try c.encode(stopDebounceSeconds, forKey: .stopDebounceSeconds)
        try c.encode(transcriptionModel, forKey: .transcriptionModel)
        try c.encode(transcriptionLanguage, forKey: .transcriptionLanguage)
        try c.encode(autoTranscribe, forKey: .autoTranscribe)
        try c.encode(autoSummarize, forKey: .autoSummarize)
        try c.encode(trackingEnabled, forKey: .trackingEnabled)
        try c.encode(semanticSearchEnabled, forKey: .semanticSearchEnabled)
        try c.encode(screenshotsEnabled, forKey: .screenshotsEnabled)
        try c.encode(screenshotIntervalMinutes, forKey: .screenshotIntervalMinutes)
        try c.encode(retentionDays, forKey: .retentionDays)
        try c.encode(excludedApps, forKey: .excludedApps)
        try c.encode(summarizerBackend, forKey: .summarizerBackend)
        try c.encode(builtInModelID, forKey: .builtInModelID)
        try c.encode(ollamaBaseURL, forKey: .ollamaBaseURL)
        try c.encode(ollamaModel, forKey: .ollamaModel)
        try c.encode(openAIBaseURL, forKey: .openAIBaseURL)
        try c.encode(openAIModel, forKey: .openAIModel)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        autoRecordMode = (try? c.decode(AutoRecordMode.self, forKey: .autoRecordMode)) ?? defaults.autoRecordMode
        stopDebounceSeconds = (try? c.decode(TimeInterval.self, forKey: .stopDebounceSeconds)) ?? defaults.stopDebounceSeconds
        transcriptionModel = (try? c.decode(TranscriptionModelChoice.self, forKey: .transcriptionModel)) ?? defaults.transcriptionModel
        if let language = try? c.decode(TranscriptionLanguage.self, forKey: .transcriptionLanguage) {
            transcriptionLanguage = language
        } else if let legacyHint = try? c.decode(String.self, forKey: .languageHint) {
            transcriptionLanguage = TranscriptionLanguage.fromLegacyHint(legacyHint)
        } else {
            transcriptionLanguage = defaults.transcriptionLanguage
        }
        autoTranscribe = (try? c.decode(Bool.self, forKey: .autoTranscribe)) ?? defaults.autoTranscribe
        autoSummarize = (try? c.decode(Bool.self, forKey: .autoSummarize)) ?? defaults.autoSummarize
        trackingEnabled = (try? c.decode(Bool.self, forKey: .trackingEnabled)) ?? defaults.trackingEnabled
        semanticSearchEnabled = (try? c.decode(Bool.self, forKey: .semanticSearchEnabled)) ?? defaults.semanticSearchEnabled
        screenshotsEnabled = (try? c.decode(Bool.self, forKey: .screenshotsEnabled)) ?? defaults.screenshotsEnabled
        screenshotIntervalMinutes = (try? c.decode(Double.self, forKey: .screenshotIntervalMinutes)) ?? defaults.screenshotIntervalMinutes
        retentionDays = (try? c.decode(Int.self, forKey: .retentionDays)) ?? defaults.retentionDays
        excludedApps = (try? c.decode(String.self, forKey: .excludedApps)) ?? defaults.excludedApps
        summarizerBackend = (try? c.decode(SummarizerBackend.self, forKey: .summarizerBackend)) ?? defaults.summarizerBackend
        builtInModelID = (try? c.decode(String.self, forKey: .builtInModelID)) ?? defaults.builtInModelID
        ollamaBaseURL = (try? c.decode(String.self, forKey: .ollamaBaseURL)) ?? defaults.ollamaBaseURL
        ollamaModel = (try? c.decode(String.self, forKey: .ollamaModel)) ?? defaults.ollamaModel
        openAIBaseURL = (try? c.decode(String.self, forKey: .openAIBaseURL)) ?? defaults.openAIBaseURL
        openAIModel = (try? c.decode(String.self, forKey: .openAIModel)) ?? defaults.openAIModel
    }
}
