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
        case appleIntelligence = "Apple Intelligence"
        case ollama = "Ollama"
        case openAICompatible = "OpenAI-compatible server"
        var id: String { rawValue }
    }

    var autoRecordMode: AutoRecordMode = .automatic
    /// Seconds the mic must be released before a meeting counts as ended.
    var stopDebounceSeconds: TimeInterval = 60

    // MARK: Calendar-assisted detection

    /// Read the Mac Calendar to confirm meetings and title recordings. Off by
    /// default and gated on a calendar TCC grant — calendar contents are
    /// sensitive, so this is strictly opt-in.
    var calendarDetectionEnabled: Bool = false
    /// Prefer the matched calendar event's title over the app-derived name.
    var useCalendarTitles: Bool = true
    /// Stricter: only auto-record a browser tab when an active calendar event
    /// with a meeting link backs it (ignores window-title-only matches).
    var requireCalendarForBrowser: Bool = false

    /// Run as a menu-bar-only app: no Dock icon, no window at launch. The
    /// recording state lives in the menu bar (live timer + indicator) so the
    /// main window is never required to know a meeting is being captured.
    /// When off, LokalBotV3 behaves like a normal windowed app with a Dock icon.
    var menuBarOnly: Bool = true

    // MARK: Models (M2)

    var transcriptionModel: TranscriptionModelChoice = .parakeetV3
    var transcriptionLanguage: TranscriptionLanguage = .auto
    var autoTranscribe: Bool = true
    var autoSummarize: Bool = true

    /// M4: app/window activity sampling.
    var trackingEnabled: Bool = true

    /// M6: embedding-based semantic search (Qwen3-Embedding, downloaded when enabled).
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
    var customBuiltInModels: [ModelCatalog.Entry] = []
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

    // MARK: - Summarisation shape

    /// Which set of section headings the summariser uses (meeting, lecture,
    /// study guide, podcast, freeform).
    var noteTemplate: NoteTemplate = .meeting
    /// Target language for the summary. `.matchTranscript` auto-detects from
    /// the transcript text; otherwise the prompt forces the chosen language.
    var summaryLanguage: SummaryLanguage = .matchTranscript
    /// Run FluidAudio's neural diarizer on `system.m4a` and split the
    /// catch-all "Them" speaker into "Them 1" / "Them 2" / … by acoustic
    /// similarity. Off by default — the model is ~100 MB and adds 30-60 s
    /// of post-processing per meeting; most users record 1:1 calls.
    var multiSpeakerDiarization: Bool = false

    // MARK: - Cotyping (inline AI autocomplete)

    /// Master switch. Off by default — cotyping needs Accessibility + Input
    /// Monitoring grants and types into other apps, so it is strictly opt-in.
    var cotypingEnabled: Bool = false
    /// Optional author name folded into the prompt as a voice cue.
    var cotypingUserName: String = ""
    /// Optional free-form style guidance ("concise", "British spelling", …).
    var cotypingStyleNote: String = ""
    /// Allow multi-line completions (off keeps suggestions to one line).
    var cotypingMultiLine: Bool = false
    /// Insert large / multi-line accepts via paste (more reliable than synthetic
    /// keystrokes in some hosts). On by default; briefly uses the clipboard and
    /// restores it.
    var cotypingPasteInsertion: Bool = true
    /// Soft length target; drives the per-request token budget. Kept short (a
    /// few words) so suggestions are quick to read and accept.
    var cotypingMaxWords: Int = 4
    /// Idle time after the last keystroke before asking the model. Low so the
    /// suggestion feels near-instant (Cotypist-style); the floor is the HTTP
    /// round-trip, not in-process decode like Cotabby/Cotypist.
    var cotypingDebounceMs: Int = 150
    /// How much the primary accept key takes (the full-accept key always takes all).
    var cotypingAcceptGranularity: CotypingAcceptGranularity = .word
    /// Primary accept key (next word/phrase) and the full-accept key (whole tail).
    var cotypingAcceptKey: CotypingAcceptKey = .tab
    var cotypingFullAcceptKey: CotypingFullAcceptKey = .backtick
    /// Comma-separated app-name / bundle-id substrings never suggested into.
    /// Preseeded with password managers and terminals.
    var cotypingExcludedApps: String = "1Password, Keychain Access, Bitwarden, KeePassXC, Terminal, iTerm"
    /// Comma-separated domains where cotyping never runs (bare host or full URL;
    /// subdomains included). Read over Accessibility in browsers only.
    var cotypingExcludedDomains: String = ""
    /// Condition suggestions on the focused app + window title / field label
    /// (e.g. the email subject or chat channel). On by default; reads window
    /// titles via Accessibility (already required for cotyping), stays on-device.
    var cotypingUseAppContext: Bool = true
    /// Fold the current clipboard into the prompt as context, so suggestions can
    /// build on what you just copied. Off by default (privacy); read fresh at
    /// generation time, never cached or persisted.
    var cotypingUseClipboard: Bool = false
    /// Match the host field's font and text color so ghost text reads as a
    /// continuation. On by default; reads via Accessibility (cached per field).
    var cotypingMatchHostStyle: Bool = true
    /// How ghost text is shown: inline at the caret, or a popup when geometry is
    /// unreliable / the caret is mid-line. `.auto` defers to caret quality.
    var cotypingMirrorPreference: CotypingMirrorPreference = .auto
    /// One-key inline autocorrect of the word you're typing (NSSpellChecker).
    /// On by default; suppresses a continuation on an unresolved typo.
    var cotypingAutocorrect: Bool = true
    /// Inline `:shortcode:` emoji autocomplete (e.g. `:rocket:` → 🚀). On by default.
    var cotypingEmoji: Bool = true
    /// Inline `/macro` autocomplete (math `/5+5`, dates `/today`, units `/10km->mi`,
    /// currency `/100usd to eur`, random `/d20`). On by default.
    var cotypingMacros: Bool = true
    /// Languages you usually write in (comma-separated) — a prompt voice hint.
    var cotypingLanguages: String = ""
    /// Free-form notes / glossary / jargon folded into the prompt as context.
    var cotypingExtendedContext: String = ""
    /// Use a model for cotyping that differs from the summarization model. Off
    /// by default — cotyping reuses the summarization engine. When on, a
    /// dedicated built-in (llama.cpp) model runs on its own server instance, so
    /// a smaller/faster model can power inline suggestions without contending
    /// with summarization for the shared server.
    var cotypingUseSeparateModel: Bool = false
    /// Built-in catalog model id used for cotyping when the toggle is on.
    var cotypingBuiltInModelID: String = ModelCatalog.recommendedCotypingID
    /// Learn from accepted continuation text, encrypted locally. Stores accepted
    /// text plus a short sanitized prefix/context hint for ranking — never full
    /// raw typing streams — and skips secure fields, terminals, and code editors.
    var cotypingUseLocalLearning: Bool = true
    /// Number of similar accepted completions folded into the next prompt.
    var cotypingLearningExamplesInPrompt: Int = 3

    var cotypingExcludedAppList: [String] {
        cotypingExcludedApps
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var cotypingExcludedDomainList: [String] {
        cotypingExcludedDomains
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Prompt personalization derived from the cotyping settings.
    var cotypingPersonalization: CotypingPersonalization {
        let langs = cotypingLanguages.trimmingCharacters(in: .whitespaces)
        let notes = cotypingExtendedContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return CotypingPersonalization(
            userName: cotypingUserName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cotypingUserName,
            styleNote: cotypingStyleNote.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cotypingStyleNote,
            languageHint: langs.isEmpty ? nil : "The text is usually written in \(langs).",
            isMultiLine: cotypingMultiLine,
            appContextEnabled: cotypingUseAppContext,
            extendedContext: notes.isEmpty ? nil : notes)
    }

    /// Token ceiling for one completion (≈3 tokens/word, with a small floor).
    var cotypingMaxResponseTokens: Int {
        max(8, min(120, cotypingMaxWords * 3))
    }

    /// Settings the cotyping engine builds its `TextEngine` from. With a
    /// separate cotyping model enabled, this is a copy pinned to the built-in
    /// backend with `cotypingBuiltInModelID`; otherwise it is `self` (cotyping
    /// reuses whatever the summarizer uses).
    var cotypingTextEngineSettings: AppSettings {
        guard cotypingUseSeparateModel else { return self }
        var s = self
        s.summarizerBackend = .builtIn
        s.builtInModelID = cotypingBuiltInModelID
        return s
    }

    /// UserDefaults key for the encoded settings blob. Internal (not private)
    /// so `DataMigration` can copy a prior install's settings under it.
    static let key = "lokalbotv3.settings"

    private enum CodingKeys: String, CodingKey {
        case autoRecordMode
        case stopDebounceSeconds
        case calendarDetectionEnabled
        case useCalendarTitles
        case requireCalendarForBrowser
        case menuBarOnly
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
        case customBuiltInModels
        case ollamaBaseURL
        case ollamaModel
        case openAIBaseURL
        case openAIModel
        case noteTemplate
        case summaryLanguage
        case multiSpeakerDiarization
        case cotypingEnabled
        case cotypingUserName
        case cotypingStyleNote
        case cotypingMultiLine
        case cotypingPasteInsertion
        case cotypingMaxWords
        case cotypingDebounceMs
        case cotypingAcceptGranularity
        case cotypingAcceptKey
        case cotypingFullAcceptKey
        case cotypingExcludedApps
        case cotypingExcludedDomains
        case cotypingUseAppContext
        case cotypingUseClipboard
        case cotypingMatchHostStyle
        case cotypingMirrorPreference
        case cotypingAutocorrect
        case cotypingEmoji
        case cotypingMacros
        case cotypingLanguages
        case cotypingExtendedContext
        case cotypingUseSeparateModel
        case cotypingBuiltInModelID
        case cotypingUseLocalLearning
        case cotypingLearningExamplesInPrompt
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
        try c.encode(calendarDetectionEnabled, forKey: .calendarDetectionEnabled)
        try c.encode(useCalendarTitles, forKey: .useCalendarTitles)
        try c.encode(requireCalendarForBrowser, forKey: .requireCalendarForBrowser)
        try c.encode(menuBarOnly, forKey: .menuBarOnly)
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
        try c.encode(customBuiltInModels, forKey: .customBuiltInModels)
        try c.encode(ollamaBaseURL, forKey: .ollamaBaseURL)
        try c.encode(ollamaModel, forKey: .ollamaModel)
        try c.encode(openAIBaseURL, forKey: .openAIBaseURL)
        try c.encode(openAIModel, forKey: .openAIModel)
        try c.encode(noteTemplate, forKey: .noteTemplate)
        try c.encode(summaryLanguage, forKey: .summaryLanguage)
        try c.encode(multiSpeakerDiarization, forKey: .multiSpeakerDiarization)
        try c.encode(cotypingEnabled, forKey: .cotypingEnabled)
        try c.encode(cotypingUserName, forKey: .cotypingUserName)
        try c.encode(cotypingStyleNote, forKey: .cotypingStyleNote)
        try c.encode(cotypingMultiLine, forKey: .cotypingMultiLine)
        try c.encode(cotypingPasteInsertion, forKey: .cotypingPasteInsertion)
        try c.encode(cotypingMaxWords, forKey: .cotypingMaxWords)
        try c.encode(cotypingDebounceMs, forKey: .cotypingDebounceMs)
        try c.encode(cotypingAcceptGranularity, forKey: .cotypingAcceptGranularity)
        try c.encode(cotypingAcceptKey, forKey: .cotypingAcceptKey)
        try c.encode(cotypingFullAcceptKey, forKey: .cotypingFullAcceptKey)
        try c.encode(cotypingExcludedApps, forKey: .cotypingExcludedApps)
        try c.encode(cotypingExcludedDomains, forKey: .cotypingExcludedDomains)
        try c.encode(cotypingUseAppContext, forKey: .cotypingUseAppContext)
        try c.encode(cotypingUseClipboard, forKey: .cotypingUseClipboard)
        try c.encode(cotypingMatchHostStyle, forKey: .cotypingMatchHostStyle)
        try c.encode(cotypingMirrorPreference, forKey: .cotypingMirrorPreference)
        try c.encode(cotypingAutocorrect, forKey: .cotypingAutocorrect)
        try c.encode(cotypingEmoji, forKey: .cotypingEmoji)
        try c.encode(cotypingMacros, forKey: .cotypingMacros)
        try c.encode(cotypingLanguages, forKey: .cotypingLanguages)
        try c.encode(cotypingExtendedContext, forKey: .cotypingExtendedContext)
        try c.encode(cotypingUseSeparateModel, forKey: .cotypingUseSeparateModel)
        try c.encode(cotypingBuiltInModelID, forKey: .cotypingBuiltInModelID)
        try c.encode(cotypingUseLocalLearning, forKey: .cotypingUseLocalLearning)
        try c.encode(cotypingLearningExamplesInPrompt, forKey: .cotypingLearningExamplesInPrompt)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        autoRecordMode = (try? c.decode(AutoRecordMode.self, forKey: .autoRecordMode)) ?? defaults.autoRecordMode
        stopDebounceSeconds = (try? c.decode(TimeInterval.self, forKey: .stopDebounceSeconds)) ?? defaults.stopDebounceSeconds
        calendarDetectionEnabled = (try? c.decode(Bool.self, forKey: .calendarDetectionEnabled)) ?? defaults.calendarDetectionEnabled
        useCalendarTitles = (try? c.decode(Bool.self, forKey: .useCalendarTitles)) ?? defaults.useCalendarTitles
        requireCalendarForBrowser = (try? c.decode(Bool.self, forKey: .requireCalendarForBrowser)) ?? defaults.requireCalendarForBrowser
        menuBarOnly = (try? c.decode(Bool.self, forKey: .menuBarOnly)) ?? defaults.menuBarOnly
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
        customBuiltInModels = (try? c.decode([ModelCatalog.Entry].self, forKey: .customBuiltInModels)) ?? defaults.customBuiltInModels
        ollamaBaseURL = (try? c.decode(String.self, forKey: .ollamaBaseURL)) ?? defaults.ollamaBaseURL
        ollamaModel = (try? c.decode(String.self, forKey: .ollamaModel)) ?? defaults.ollamaModel
        openAIBaseURL = (try? c.decode(String.self, forKey: .openAIBaseURL)) ?? defaults.openAIBaseURL
        openAIModel = (try? c.decode(String.self, forKey: .openAIModel)) ?? defaults.openAIModel
        noteTemplate = (try? c.decode(NoteTemplate.self, forKey: .noteTemplate)) ?? defaults.noteTemplate
        summaryLanguage = (try? c.decode(SummaryLanguage.self, forKey: .summaryLanguage)) ?? defaults.summaryLanguage
        multiSpeakerDiarization = (try? c.decode(Bool.self, forKey: .multiSpeakerDiarization)) ?? defaults.multiSpeakerDiarization
        cotypingEnabled = (try? c.decode(Bool.self, forKey: .cotypingEnabled)) ?? defaults.cotypingEnabled
        cotypingUserName = (try? c.decode(String.self, forKey: .cotypingUserName)) ?? defaults.cotypingUserName
        cotypingStyleNote = (try? c.decode(String.self, forKey: .cotypingStyleNote)) ?? defaults.cotypingStyleNote
        cotypingMultiLine = (try? c.decode(Bool.self, forKey: .cotypingMultiLine)) ?? defaults.cotypingMultiLine
        cotypingPasteInsertion = (try? c.decode(Bool.self, forKey: .cotypingPasteInsertion)) ?? defaults.cotypingPasteInsertion
        cotypingMaxWords = (try? c.decode(Int.self, forKey: .cotypingMaxWords)) ?? defaults.cotypingMaxWords
        cotypingDebounceMs = (try? c.decode(Int.self, forKey: .cotypingDebounceMs)) ?? defaults.cotypingDebounceMs
        cotypingAcceptGranularity = (try? c.decode(CotypingAcceptGranularity.self, forKey: .cotypingAcceptGranularity)) ?? defaults.cotypingAcceptGranularity
        cotypingAcceptKey = (try? c.decode(CotypingAcceptKey.self, forKey: .cotypingAcceptKey)) ?? defaults.cotypingAcceptKey
        cotypingFullAcceptKey = (try? c.decode(CotypingFullAcceptKey.self, forKey: .cotypingFullAcceptKey)) ?? defaults.cotypingFullAcceptKey
        cotypingExcludedApps = (try? c.decode(String.self, forKey: .cotypingExcludedApps)) ?? defaults.cotypingExcludedApps
        cotypingExcludedDomains = (try? c.decode(String.self, forKey: .cotypingExcludedDomains)) ?? defaults.cotypingExcludedDomains
        cotypingUseAppContext = (try? c.decode(Bool.self, forKey: .cotypingUseAppContext)) ?? defaults.cotypingUseAppContext
        cotypingUseClipboard = (try? c.decode(Bool.self, forKey: .cotypingUseClipboard)) ?? defaults.cotypingUseClipboard
        cotypingMatchHostStyle = (try? c.decode(Bool.self, forKey: .cotypingMatchHostStyle)) ?? defaults.cotypingMatchHostStyle
        cotypingMirrorPreference = (try? c.decode(CotypingMirrorPreference.self, forKey: .cotypingMirrorPreference)) ?? defaults.cotypingMirrorPreference
        cotypingAutocorrect = (try? c.decode(Bool.self, forKey: .cotypingAutocorrect)) ?? defaults.cotypingAutocorrect
        cotypingEmoji = (try? c.decode(Bool.self, forKey: .cotypingEmoji)) ?? defaults.cotypingEmoji
        cotypingMacros = (try? c.decode(Bool.self, forKey: .cotypingMacros)) ?? defaults.cotypingMacros
        cotypingLanguages = (try? c.decode(String.self, forKey: .cotypingLanguages)) ?? defaults.cotypingLanguages
        cotypingExtendedContext = (try? c.decode(String.self, forKey: .cotypingExtendedContext)) ?? defaults.cotypingExtendedContext
        cotypingUseSeparateModel = (try? c.decode(Bool.self, forKey: .cotypingUseSeparateModel)) ?? defaults.cotypingUseSeparateModel
        cotypingBuiltInModelID = (try? c.decode(String.self, forKey: .cotypingBuiltInModelID)) ?? defaults.cotypingBuiltInModelID
        cotypingUseLocalLearning = (try? c.decode(Bool.self, forKey: .cotypingUseLocalLearning)) ?? defaults.cotypingUseLocalLearning
        let learnedCount = (try? c.decode(Int.self, forKey: .cotypingLearningExamplesInPrompt)) ?? defaults.cotypingLearningExamplesInPrompt
        cotypingLearningExamplesInPrompt = min(5, max(1, learnedCount))
    }
}
