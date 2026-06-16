import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    @State private var ollamaModels: [String] = []
    @State private var ollamaReachable = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var preparingTranscriptionModelID: String?
    @State private var readyTranscriptionModelIDs: Set<String> = []
    @State private var transcriptionModelErrors: [String: String] = [:]
    @State private var transcriptionModelProgress: [String: Double] = [:]
    @State private var transcriptionModelStatus: [String: String] = [:]

    var body: some View {
        Form {
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

            Section("Summarization") {
                Toggle("Summarize automatically after transcription", isOn: $app.settings.autoSummarize)
                Picker("Backend", selection: $app.settings.summarizerBackend) {
                    ForEach(AppSettings.SummarizerBackend.allCases) { backend in
                        Text(backend.rawValue).tag(backend)
                    }
                }

                switch app.settings.summarizerBackend {
                case .builtIn:
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ModelCatalog.entries) { entry in
                            ModelCatalogRow(entry: entry)
                        }
                        Text("Runs on the bundled llama.cpp server (Metal) — nothing to install. Downloads come from Hugging Face.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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

            Section("Day tracking") {
                Toggle("Track app & window activity", isOn: Binding(
                    get: { app.settings.trackingEnabled },
                    set: { app.settings.trackingEnabled = $0; app.applyTrackingSetting() }))
                LabeledContent("Window titles") {
                    if ActivitySampler.hasAccessibility {
                        Text("Accessibility granted").foregroundStyle(.secondary)
                    } else {
                        Button("Grant Accessibility access…") {
                            ActivitySampler.requestAccessibility()
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

            Section("Storage") {
                LabeledContent("Location") {
                    Button(app.storage.rootURL.path(percentEncoded: false)) {
                        NSWorkspace.shared.activateFileViewerSelecting([app.storage.rootURL])
                    }
                    .buttonStyle(.link)
                }
            }
            Section("Privacy") {
                Label("Audio and transcripts never leave this Mac. Network access is localhost (your LLM server) plus user-initiated model downloads from Hugging Face.",
                      systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
        .navigationTitle("Settings")
        .task { await refreshOllama() }
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
