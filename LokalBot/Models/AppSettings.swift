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

    var autoRecordMode: AutoRecordMode = .ask
    /// Seconds the mic must be released before a meeting counts as ended.
    var stopDebounceSeconds: TimeInterval = 60

    // MARK: Models (M2)

    var transcriptionModel: TranscriptionModelChoice = .parakeetV3
    /// ISO 639-1 hint for v3 token filtering ("en", "de", …); empty = auto.
    var languageHint: String = ""
    var autoTranscribe: Bool = true
    var autoSummarize: Bool = true

    /// M4: app/window activity sampling.
    var trackingEnabled: Bool = true

    /// M6: embedding-based semantic search (nomic-embed, auto-downloaded).
    var semanticSearchEnabled: Bool = true

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
    var openAIAPIKey: String = ""

    private static let key = "lokalbot.settings"

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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        autoRecordMode = (try? c.decode(AutoRecordMode.self, forKey: .autoRecordMode)) ?? defaults.autoRecordMode
        stopDebounceSeconds = (try? c.decode(TimeInterval.self, forKey: .stopDebounceSeconds)) ?? defaults.stopDebounceSeconds
        transcriptionModel = (try? c.decode(TranscriptionModelChoice.self, forKey: .transcriptionModel)) ?? defaults.transcriptionModel
        languageHint = (try? c.decode(String.self, forKey: .languageHint)) ?? defaults.languageHint
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
        openAIAPIKey = (try? c.decode(String.self, forKey: .openAIAPIKey)) ?? defaults.openAIAPIKey
    }
}
