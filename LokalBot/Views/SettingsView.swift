import SwiftUI
import LaunchAtLogin

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    @State private var ollamaModels: [String] = []
    @State private var ollamaReachable = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var preparingTranscriptionModelID: String?
    @State private var readyTranscriptionModelIDs: Set<String> = []
    @State private var transcriptionModelErrors: [String: String] = [:]
    @State private var transcriptionModelProgress: [String: Double] = [:]
    @State private var transcriptionModelStatus: [String: String] = [:]
    @StateObject private var updates = AppUpdateManager.shared
    @State private var cliMessage: String?

    // Settings search + live system readouts + Hugging Face browse.
    @State private var settingsQuery = ""
    @StateObject private var power = PowerSourceMonitor()
    @ObservedObject private var metrics = GenerationMetricsStore.shared
    @ObservedObject private var cotypingStats = CotypingStatsStore.shared
    @StateObject private var hfSearch = HuggingFaceSearchService()
    @State private var showingHFBrowse = false
    @State private var hfSelectedModel: String?
    @State private var hfFiles: [HFFile] = []

    var body: some View {
        Form {
            Section {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search settings…", text: $settingsQuery)
                        .textFieldStyle(.plain)
                    if !settingsQuery.isEmpty {
                        Button { settingsQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }

            if shows("General", ["launch", "login", "startup", "open at login", "auto start",
                                 "menu bar", "menubar", "dock", "window", "background", "tray"]) {
                Section("General") {
                    LaunchAtLogin.Toggle("Launch LokalBotV3 at login")
                    Text("Start LokalBotV3 automatically so it's ready to catch meetings.")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("Menu bar only (hide Dock icon)", isOn: $app.settings.menuBarOnly)
                        .onChange(of: app.settings.menuBarOnly) { _, menuBarOnly in
                            DockPolicy.sync()
                            if !menuBarOnly { openWindow(id: "main") }
                        }
                    Text("Run from the menu bar with a live recording timer — no Dock icon, no window at launch. The window stays one click away. Takes full effect once open windows are closed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if shows("Meetings", ["meeting", "auto record", "detect", "debounce", "recording"]) {
                Section("Meetings") {
                    Picker("When a meeting is detected", selection: $app.settings.autoRecordMode) {
                        ForEach(AppSettings.AutoRecordMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    LabeledContent("Detected apps") {
                        Text(Set(MeetingDetector.knownApps.values).sorted().joined(separator: ", ")
                             + " + browser meetings (Meet, Jitsi, Whereby)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Stop debounce") {
                        Text("\(Int(app.settings.stopDebounceSeconds)) s after mic releases")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if shows("Transcription", ["transcribe", "transcription", "language", "parakeet", "whisper", "speech", "model"]) {
                Section("Transcription") {
                    ForEach(TranscriptionModelChoice.allCases) { choice in
                        TranscriptionModelRow(
                            choice: choice,
                            preparing: preparingTranscriptionModelID == choice.id,
                            prepareDisabled: preparingTranscriptionModelID != nil,
                            ready: readyTranscriptionModelIDs.contains(choice.id),
                            error: transcriptionModelErrors[choice.id],
                            progress: transcriptionModelProgress[choice.id],
                            status: transcriptionModelStatus[choice.id]
                        ) {
                            Task { await prepareTranscriptionModel(choice) }
                        }
                    }
                    Picker("Language", selection: $app.settings.transcriptionLanguage) {
                        ForEach(TranscriptionLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .frame(maxWidth: 320)
                    Toggle("Transcribe automatically after each meeting", isOn: $app.settings.autoTranscribe)
                    Text("Runs fully on-device (CoreML / Neural Engine). Models fetch from Hugging Face on first use — or use Download to cache and warm one up.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if shows("Summarization", ["summary", "summarize", "notes", "template", "backend", "llm", "ollama", "openai", "apple intelligence", "diarization", "speaker", "model", "hugging face"]) {
                Section("Summarization") {
                    Toggle("Summarize automatically after transcription", isOn: $app.settings.autoSummarize)
                    Picker("Notes template", selection: $app.settings.noteTemplate) {
                        ForEach(NoteTemplate.allCases) { template in
                            Text("\(template.displayName)").tag(template)
                        }
                    }
                    Text(app.settings.noteTemplate.description)
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Notes language", selection: $app.settings.summaryLanguage) {
                        Text("Match transcript (auto)").tag(SummaryLanguage.matchTranscript)
                        Divider()
                        ForEach(SummaryLanguage.presets, id: \.rawValue) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    Toggle("Split \"Them\" by speaker (neural diarization)",
                           isOn: $app.settings.multiSpeakerDiarization)
                    Text("Adds 30–60 s of post-processing per meeting. First run downloads ~100 MB of speaker models from Hugging Face.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Backend", selection: $app.settings.summarizerBackend) {
                        ForEach(AppSettings.SummarizerBackend.allCases) { backend in
                            Text(backend.rawValue).tag(backend)
                        }
                    }

                    switch app.settings.summarizerBackend {
                    case .builtIn:
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(ModelCatalog.selectableEntries(custom: app.settings.customBuiltInModels)) { entry in
                                ModelCatalogRow(entry: entry)
                            }
                            Button("Browse Hugging Face…") { showingHFBrowse = true }
                                .controlSize(.small)
                            Text("Runs on the bundled llama.cpp server (Metal) — nothing to install. Downloads come from Hugging Face.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .appleIntelligence:
                        let availability = FoundationModelAvailability.current()
                        LabeledContent("Status") {
                            HStack(spacing: 6) {
                                Circle().fill(availability.isAvailable ? .green : .orange)
                                    .frame(width: 8, height: 8)
                                Text(availability.isAvailable
                                     ? "Available — Apple's on-device model."
                                     : (availability.reason ?? "Unavailable"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("Uses Apple Intelligence (macOS 26+). No model download; nothing leaves your Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .ollama:
                        TextField("Server", text: $app.settings.ollamaBaseURL)
                        LabeledContent("Status") {
                            HStack(spacing: 6) {
                                Circle().fill(ollamaReachable ? .green : .red).frame(width: 8, height: 8)
                                Text(ollamaReachable
                                     ? "Running · \(ollamaModels.count) model\(ollamaModels.count == 1 ? "" : "s")"
                                     : "Not reachable — start with `ollama serve`")
                                    .foregroundStyle(.secondary)
                                Button("Refresh") { Task { await refreshOllama() } }
                                    .controlSize(.small)
                            }
                        }
                        if !ollamaModels.isEmpty {
                            Picker("Model", selection: $app.settings.ollamaModel) {
                                Text("— pick a model —").tag("")
                                ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    case .openAICompatible:
                        TextField("Base URL (…/v1)", text: $app.settings.openAIBaseURL)
                        TextField("Model name", text: $app.settings.openAIModel)
                        SecureField("API key (optional)", text: $app.settings.openAIAPIKey)
                    }

                    HStack(spacing: 8) {
                        Button(testing ? "Testing…" : "Test generation") {
                            Task { await testGeneration() }
                        }
                        .disabled(testing)
                        if let testResult {
                            Text(testResult).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }

            if shows("Cotyping", ["cotyping", "autocomplete", "inline", "ghost", "suggestion", "typing", "complete", "tab", "autocorrect"]) {
                Section("Cotyping") {
                    Toggle("Inline AI autocomplete (cotyping)", isOn: $app.settings.cotypingEnabled)
                    Text("Suggests text inline as you type in other apps, using your summarization model. Needs Accessibility + Input Monitoring. Open the Cotyping tab for setup and a live preview.")
                        .font(.caption).foregroundStyle(.secondary)
                    if app.settings.cotypingEnabled {
                        TextField("Your name (optional — tunes the voice)", text: $app.settings.cotypingUserName)
                        TextField("Writing style (optional, e.g. \u{201c}concise, British spelling\u{201d})", text: $app.settings.cotypingStyleNote)
                        TextField("Languages you write in (optional, e.g. \u{201c}English, German\u{201d})",
                                  text: $app.settings.cotypingLanguages)
                        TextField("Notes / glossary (optional — names, jargon, style)",
                                  text: $app.settings.cotypingExtendedContext, axis: .vertical)
                            .lineLimit(1...3)
                        Stepper("Suggestion length: up to \(app.settings.cotypingMaxWords) words",
                                value: $app.settings.cotypingMaxWords, in: 2...30)
                        Toggle("Allow multi-line suggestions", isOn: $app.settings.cotypingMultiLine)
                        Toggle("Use app & window context", isOn: $app.settings.cotypingUseAppContext)
                        Text("Conditions suggestions on the focused app and its window title (email subject, chat channel, page title) for sharper, on-topic completions. Read locally via Accessibility; skipped in code editors and terminals.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Match the app\u{2019}s font and text color", isOn: $app.settings.cotypingMatchHostStyle)
                        Text("Ghost text mimics the field you\u{2019}re typing in (font family and a dimmed version of its text color) instead of a fixed style. Read locally via Accessibility; cached per field.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Show suggestions", selection: $app.settings.cotypingMirrorPreference) {
                            ForEach(CotypingMirrorPreference.allCases) { Text($0.label).tag($0) }
                        }
                        Text("\u{201c}Automatic\u{201d} draws ghost text inline at the caret, but falls back to a popup below the caret when its geometry is unreliable or the caret is mid-line.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Autocorrect the word you're typing", isOn: $app.settings.cotypingAutocorrect)
                        Text("Spots a misspelled word and offers the fix inline — Tab swaps it. Uses the macOS spell checker (on-device); never touches code, URLs, or numbers.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Emoji autocomplete (\u{201c}:rocket:\u{201d} \u{2192} \u{1f680})", isOn: $app.settings.cotypingEmoji)
                        Toggle("Macros (\u{201c}/5+5\u{201d}, \u{201c}/today\u{201d}, \u{201c}/10km->mi\u{201d})", isOn: $app.settings.cotypingMacros)
                        Text("Type \u{201c}/\u{201d} then an expression — math, dates, unit/currency conversion, or random — and the result shows inline. Accept to swap it in.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Accept next", selection: $app.settings.cotypingAcceptKey) {
                            ForEach(CotypingAcceptKey.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Each accept takes", selection: $app.settings.cotypingAcceptGranularity) {
                            ForEach(CotypingAcceptGranularity.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Accept whole suggestion", selection: $app.settings.cotypingFullAcceptKey) {
                            ForEach(CotypingFullAcceptKey.allCases) { Text($0.label).tag($0) }
                        }
                        LabeledContent("Pause before suggesting") {
                            Text("\(app.settings.cotypingDebounceMs) ms").foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(app.settings.cotypingDebounceMs) },
                            set: { app.settings.cotypingDebounceMs = Int($0) }),
                            in: 100...1000, step: 50)
                        TextField("Never suggest in (app names, comma-separated)",
                                  text: $app.settings.cotypingExcludedApps)
                        Text("Cotyping never runs in password fields. Add apps (or terminals) here to exclude them too.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Never suggest on (websites, comma-separated)",
                                  text: $app.settings.cotypingExcludedDomains)
                        Text("Block cotyping on specific sites (e.g. \u{201c}bank.com\u{201d}). Subdomains included; read locally via Accessibility in browsers.")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider().padding(.vertical, 2)
                        LabeledContent("Suggestions generated") {
                            Text("\(cotypingStats.stats.generations)").foregroundStyle(.secondary)
                        }
                        LabeledContent("Accepted") {
                            Text("\(cotypingStats.stats.accepts)  (\(String(format: "%.2f", cotypingStats.stats.acceptsPerGeneration))/gen)").foregroundStyle(.secondary)
                        }
                        LabeledContent("Characters inserted") {
                            Text("\(cotypingStats.stats.charsAccepted)").foregroundStyle(.secondary)
                        }
                        if cotypingStats.stats.errors > 0 {
                            LabeledContent("Failed generations") {
                                Text("\(cotypingStats.stats.errors)").foregroundStyle(.secondary)
                            }
                        }
                        if let avg = cotypingStats.stats.avgLatencyMs {
                            LabeledContent("Generation latency") {
                                Text("avg \(avg) ms · p95 \(cotypingStats.stats.p95LatencyMs ?? avg) · max \(cotypingStats.stats.maxLatencyMs ?? avg)").foregroundStyle(.secondary)
                            }
                        }
                        if cotypingStats.stats != CotypingStats() {
                            Button("Reset cotyping stats", role: .destructive) { cotypingStats.clear() }
                                .font(.caption)
                        }
                    }
                }
            }

            if shows("Day tracking", ["tracking", "activity", "screenshots", "ocr", "window", "accessibility", "retention", "private"]) {
                Section("Day tracking") {
                    Toggle("Track app & window activity", isOn: Binding(
                        get: { app.settings.trackingEnabled },
                        set: { app.settings.trackingEnabled = $0; app.applyTrackingSetting() }))
                    LabeledContent("Window titles") {
                        if ActivitySampler.hasAccessibility {
                            Text("Accessibility granted").foregroundStyle(.secondary)
                        } else {
                            Button("Grant Accessibility access…") {
                                PermissionManager.shared.request(.accessibility)
                                PermissionManager.shared.openSettings(for: .accessibility)
                            }
                        }
                    }
                    Toggle("Periodic screenshots (OCR'd locally, encrypted at rest)", isOn: Binding(
                        get: { app.settings.screenshotsEnabled },
                        set: { app.settings.screenshotsEnabled = $0; app.screenshots.restart() }))
                    if app.settings.screenshotsEnabled {
                        Slider(value: Binding(
                            get: { app.settings.screenshotIntervalMinutes },
                            set: { app.settings.screenshotIntervalMinutes = $0; app.screenshots.restart() }),
                            in: 1...15, step: 1) {
                            Text("Every \(Int(app.settings.screenshotIntervalMinutes)) min")
                        }
                        Stepper("Keep screenshots \(app.settings.retentionDays) days",
                                value: $app.settings.retentionDays, in: 1...90)
                    }
                    TextField("Never capture (app names, comma-separated)",
                              text: $app.settings.excludedApps)
                    Text("Sampled every 5 s, idle-aware (3 min); never captures the lock screen. Screenshots are AES-GCM encrypted (key in your Keychain); extracted text stays searchable after pixels are pruned. Excluded apps log as “Private”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if shows("Search", ["search", "semantic", "embeddings", "meaning"]) {
                Section("Search") {
                    Toggle("Semantic search (embeddings)", isOn: Binding(
                        get: { app.settings.semanticSearchEnabled },
                        set: { enabled in
                            app.settings.semanticSearchEnabled = enabled
                            if enabled {
                                Task { await app.embeddingIndex.reindexAll(app.meetings) }
                            }
                        }))
                    Text("Finds meetings by meaning, not just keywords. Uses nomic-embed-text (146 MB), downloaded when you enable semantic search.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if shows("Storage", ["storage", "location", "files", "folder", "disk"]) {
                Section("Storage") {
                    LabeledContent("Location") {
                        Button(app.storage.rootURL.path(percentEncoded: false)) {
                            NSWorkspace.shared.activateFileViewerSelecting([app.storage.rootURL])
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            if shows("Updates", ["update", "version", "sparkle", "upgrade", "check", "release"]) {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.automaticallyChecksForUpdates = $0 }))
                    LabeledContent("Current version") {
                        Text(AppUpdateManager.currentVersionString).foregroundStyle(.secondary)
                    }
                    Button("Check for Updates…") {
                        AppUpdateManager.shared.checkForUpdates()
                    }
                    .disabled(!updates.isStarted)
                    Text(updates.isStarted
                         ? "Updates are signed and delivered via Sparkle. LokalBot stays local-first — only the appcast and the chosen download are fetched."
                         : "Updater inactive — set the appcast feed URL and Sparkle public key before shipping (see RELEASING.md).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if shows("System", ["system", "hardware", "ram", "memory", "chip", "cpu", "battery", "power", "diagnostics", "performance", "generations"]) {
                Section("System") {
                    LabeledContent("This Mac") {
                        Text(DeviceInfo.snapshot().summaryLine)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    if power.isLowPower {
                        Label("Low Power Mode is on — summaries may run slower.", systemImage: "bolt.slash")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if power.isOnBattery {
                        Label("Running on battery.", systemImage: "battery.75")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if metrics.recent.isEmpty {
                        Text("No model generations recorded yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(metrics.recent.reversed().prefix(5))) { metric in
                            LabeledContent(metric.label) {
                                Text(String(format: "%.1fs · ~%d tok · %.0f tok/s",
                                            metric.durationSec, metric.approxTokens, metric.tokensPerSec))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if shows("Agent CLI", ["cli", "agent", "terminal", "claude", "codex", "cursor", "gemini", "symlink", "install"]) {
                Section("Agent CLI") {
                    let installer = LokalBotCLIInstaller.bundled
                    if installer.bundledBinary == nil {
                        Text("This build doesn't ship lokalbot-cli. Build the lokalbot-cli scheme once before opening Settings.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Status") {
                            if installer.isInstalled {
                                Label("Installed", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if !installer.isBundleLocationStable {
                                Label("Move LokalBotV3.app to /Applications first",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            } else {
                                Label("Not installed", systemImage: "circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Button(installer.isInstalled ? "Reinstall…" : "Install for your coding agent…") {
                                cliMessage = nil
                                do {
                                    try installer.install()
                                    cliMessage = "Installed at \(installer.binLink.path(percentEncoded: false))."
                                } catch {
                                    cliMessage = "Install failed: \(error.localizedDescription)"
                                }
                            }
                            .disabled(!installer.isBundleLocationStable)
                            if installer.isInstalled {
                                Button("Uninstall", role: .destructive) {
                                    cliMessage = nil
                                    do {
                                        try installer.uninstall()
                                        cliMessage = "Removed lokalbot-cli symlinks."
                                    } catch {
                                        cliMessage = "Uninstall failed: \(error.localizedDescription)"
                                    }
                                }
                            }
                            if !installer.localBinOnPath {
                                Button("Add ~/.local/bin to PATH") {
                                    cliMessage = nil
                                    do {
                                        try installer.addLocalBinToPath()
                                        cliMessage = "Appended to ~/.zshrc — open a new terminal."
                                    } catch {
                                        cliMessage = error.localizedDescription
                                    }
                                }
                            }
                        }
                        if let cliMessage {
                            Text(cliMessage).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Symlinks the bundled CLI at ~/.local/bin/lokalbot-cli and the skill at ~/.agents/skills/lokalbot-cli. Read-only by design.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if shows("Privacy", ["privacy", "local", "network", "data", "security"]) {
                Section("Privacy") {
                    Label("Audio and transcripts never leave this Mac. Network access is localhost (your LLM server) plus user-initiated model downloads from Hugging Face.",
                          systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
        .navigationTitle("Settings")
        .task { await refreshOllama() }
        .onAppear { power.start() }
        .onDisappear { power.stop() }
        .sheet(isPresented: $showingHFBrowse) { huggingFaceBrowser }
    }

    /// A section is visible when the search field is empty or its title/keywords
    /// match the query (every query token must appear).
    private func shows(_ title: String, _ keywords: [String]) -> Bool {
        SettingsSearchRanker.matches(query: settingsQuery, haystack: [title] + keywords)
    }

    // MARK: - Hugging Face browse sheet

    private var huggingFaceBrowser: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Browse Hugging Face").font(.headline)
                Spacer()
                Button("Done") { showingHFBrowse = false }
            }
            .padding()
            Divider()
            HStack {
                TextField("Search GGUF models (e.g. qwen, llama)…", text: $hfSearch.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await hfSearch.search() } }
                Button("Search") { Task { await hfSearch.search() } }
                    .disabled(hfSearch.query.trimmingCharacters(in: .whitespaces).isEmpty)
                if hfSearch.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(12)
            if let error = hfSearch.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            List {
                ForEach(hfSearch.results) { model in
                    Button {
                        Task {
                            hfSelectedModel = model.id
                            hfFiles = await hfSearch.ggufFiles(for: model.id)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.id).font(.system(size: 12.5, weight: .medium))
                                Text("↓ \(model.downloads)   ♥ \(model.likes)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: hfSelectedModel == model.id ? "chevron.down" : "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    if hfSelectedModel == model.id {
                        if hfFiles.isEmpty {
                            Text("No .gguf files in this repo.")
                                .font(.caption2).foregroundStyle(.secondary).padding(.leading, 16)
                        } else {
                            ForEach(hfFiles) { file in
                                HStack(spacing: 8) {
                                    Text(file.fileName).font(.caption)
                                    if let size = file.sizeLabel {
                                        Text(size).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Download") {
                                        let entry = ModelCatalog.Entry(
                                            id: "hf:\(file.modelID)/\(file.id)",
                                            displayName: file.fileName,
                                            fileName: file.fileName,
                                            url: file.downloadURL.absoluteString,
                                            sizeGB: file.sizeBytes.map { Double($0) / 1_000_000_000 } ?? 0,
                                            blurb: "Downloaded from \(file.modelID).",
                                            disablesThinking: false)
                                        app.settings.customBuiltInModels.removeAll { $0.id == entry.id }
                                        app.settings.customBuiltInModels.append(entry)
                                        app.settings.builtInModelID = entry.id
                                        app.settings.summarizerBackend = .builtIn
                                        ModelDownloadManager.shared.download(
                                            url: entry.url,
                                            fileName: entry.fileName,
                                            id: entry.id,
                                            storage: app.storage)
                                        showingHFBrowse = false
                                    }
                                    .controlSize(.small)
                                }
                                .padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 580, height: 460)
    }

    private func refreshOllama() async {
        guard let url = URL(string: app.settings.ollamaBaseURL) else { return }
        let models = await OllamaEngine.listModels(baseURL: url)
        ollamaModels = models
        ollamaReachable = !models.isEmpty
        // Sensible default: first available model if none picked yet.
        if app.settings.ollamaModel.isEmpty, let first = models.first {
            app.settings.ollamaModel = first
        }
    }

    private struct ModelCatalogRow: View {
        @EnvironmentObject var app: AppState
        @ObservedObject var downloads = ModelDownloadManager.shared
        let entry: ModelCatalog.Entry

        var body: some View {
            let available = ModelCatalog.localURL(for: entry, storage: app.storage) != nil
            let selected = app.settings.builtInModelID == entry.id
            let fit = ModelFit.evaluate(modelSizeGB: entry.sizeGB,
                                        capability: HardwareCapabilityProbe.current())
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .onTapGesture { if available { app.settings.builtInModelID = entry.id } }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(entry.displayName).font(.system(size: 12.5, weight: .medium))
                        if entry.isBundled {
                            Text("BUILT-IN").font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.green.opacity(0.2), in: Capsule())
                        }
                    }
                    Text("\(String(format: "%.1f", entry.sizeGB)) GB · \(entry.blurb)")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let advisory = fit.advisory {
                        Text(advisory).font(.caption2)
                            .foregroundStyle(fit == .tooLarge ? .orange : .secondary)
                    }
                    if let error = downloads.errors[entry.id] {
                        Text(error).font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer()
                if let fraction = downloads.progress[entry.id] {
                    ProgressView(value: fraction).frame(width: 70)
                    Button("Cancel") { downloads.cancel(entry) }.controlSize(.mini)
                } else if available {
                    if !entry.isBundled {
                        Button("Delete") { downloads.delete(entry, storage: app.storage) }
                            .controlSize(.mini)
                    }
                } else {
                    Button("Download") { downloads.download(entry, storage: app.storage) }
                        .controlSize(.small)
                }
            }
            .opacity(available || downloads.progress[entry.id] != nil ? 1 : 0.75)
        }
    }

    private struct TranscriptionModelRow: View {
        @EnvironmentObject var app: AppState
        let choice: TranscriptionModelChoice
        let preparing: Bool
        let prepareDisabled: Bool
        let ready: Bool
        let error: String?
        let progress: Double?
        let status: String?
        let prepare: () -> Void

        var body: some View {
            let selected = app.settings.transcriptionModel == choice
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .onTapGesture { app.settings.transcriptionModel = choice }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(choice.rawValue).font(.system(size: 12.5, weight: .medium))
                        if ready {
                            Text("READY").font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.green.opacity(0.2), in: Capsule())
                        }
                    }
                    Text(choice.blurb).font(.caption2).foregroundStyle(.secondary)
                    if let error {
                        Text(error).font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer()
                if preparing {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let progress {
                            ProgressView(value: progress).frame(width: 84)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .frame(width: 84)
                        }
                        Text(status ?? "Preparing...")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else if !ready {
                    Button("Download") { prepare() }
                        .controlSize(.small)
                        .disabled(prepareDisabled)
                }
            }
            .opacity(selected || ready || preparing ? 1 : 0.75)
        }
    }

    private func prepareTranscriptionModel(_ choice: TranscriptionModelChoice) async {
        guard preparingTranscriptionModelID == nil else { return }
        let id = choice.id
        preparingTranscriptionModelID = choice.id
        transcriptionModelErrors[choice.id] = nil
        transcriptionModelProgress[choice.id] = nil
        transcriptionModelStatus[choice.id] = "Preparing..."
        defer {
            preparingTranscriptionModelID = nil
            transcriptionModelProgress[id] = nil
            transcriptionModelStatus[id] = nil
        }
        let progressHandler: ModelPreparationProgressHandler = { update in
            guard preparingTranscriptionModelID == id else { return }
            transcriptionModelProgress[id] = update.fractionCompleted
            transcriptionModelStatus[id] = update.status
        }
        do {
            switch choice {
            case .parakeetV3:
                await ParakeetEngine.shared.setVariant(.v3)
                try await ParakeetEngine.shared.prepare(progress: progressHandler)
            case .parakeetV2:
                await ParakeetEngine.shared.setVariant(.v2)
                try await ParakeetEngine.shared.prepare(progress: progressHandler)
            case .whisperLarge:
                try await WhisperEngine.shared.prepare(progress: progressHandler)
            case .cohere:
                try await CohereEngine.shared.prepare(progress: progressHandler)
            }
            readyTranscriptionModelIDs.insert(choice.id)
        } catch {
            transcriptionModelErrors[choice.id] = error.localizedDescription
        }
    }

    private func testGeneration() async {
        testing = true
        testResult = nil
        defer { testing = false }
        do {
            let engine = try await app.pipeline.makeTextEngine(app.settings)
            let reply = try await engine.generate(
                system: "You are a connectivity test. Reply with one short sentence.",
                prompt: "Say hello and name the model you are.",
                context: [])
            testResult = "✓ " + reply.prefix(120)
        } catch {
            testResult = "✗ \(error.localizedDescription)"
        }
    }
}
