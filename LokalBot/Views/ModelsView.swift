import SwiftUI
import AppKit

/// The Models tab of Settings (spec §2.5). All model selection and management
/// lives here, a dedicated card-per-role surface: Transcription, Main LLM
/// engine, Cotyping, and Embeddings each pick and manage their own model.
/// Downloads come from the local catalog or Hugging Face.
struct ModelsView: View {
    @EnvironmentObject var app: AppState

    @State private var ollamaModels: [String] = []
    @State private var ollamaReachable = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var preparingTranscriptionModelID: String?
    @State private var downloadedTranscriptionModelIDs: Set<String> = []
    @State private var readyTranscriptionModelIDs: Set<String> = []
    @State private var transcriptionModelErrors: [String: String] = [:]
    @State private var transcriptionModelProgress: [String: Double] = [:]
    @State private var transcriptionModelStatus: [String: String] = [:]
    @State private var speechModelDownloaded = false
    @State private var preparingSpeechModel = false
    @State private var speechModelError: String?
    @State private var speechModelStatus: String?
    @State private var speechModelProgress: Double?
    @StateObject private var hfSearch = HuggingFaceSearchService()
    @State private var showingHFBrowse = false
    @State private var hfSelectedModel: String?
    @State private var hfFiles: [HFFile] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ModelMemoryBanner()
                transcriptionCard
                summarizationCard
                speechCard
                cotypingCard
                embeddingsCard
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            refreshTranscriptionDownloads()
            refreshSpeechModel()
            await refreshOllama()
        }
        .onAppear {
            refreshTranscriptionDownloads()
            refreshSpeechModel()
        }
        .sheet(isPresented: $showingHFBrowse) { huggingFaceBrowser }
    }

    // MARK: - Cards

    /// Live model-memory line fed by `ModelResidency`: which weights are
    /// resident right now, their approximate RAM, and the eviction budget.
    private struct ModelMemoryBanner: View {
        @ObservedObject private var residency = ModelResidency.shared

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .foregroundStyle(.tint)
                if residency.residents.isEmpty {
                    Text("No models in memory — weights load on demand and are evicted "
                        + "least-recently-used past \(gigabytes(residency.budgetBytes)).")
                } else {
                    Text("Models in memory: **\(gigabytes(residency.totalBytes))** of "
                        + "\(gigabytes(residency.budgetBytes)) budget — "
                        + residency.residents.map(\.label).joined(separator: ", "))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("models.residency")
        }

        private func gigabytes(_ bytes: Int64) -> String {
            String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        }
    }

    private var transcriptionCard: some View {
        ModelCard(icon: "waveform", title: "Transcription",
                  subtitle: "Speech → text for meeting audio") {
            ForEach(visibleTranscriptionChoices) { choice in
                TranscriptionModelRow(
                    choice: choice,
                    preparing: preparingTranscriptionModelID == choice.id,
                    prepareDisabled: preparingTranscriptionModelID != nil,
                    downloaded: downloadedTranscriptionModelIDs.contains(choice.id),
                    ready: readyTranscriptionModelIDs.contains(choice.id),
                    error: transcriptionModelErrors[choice.id],
                    progress: transcriptionModelProgress[choice.id],
                    status: transcriptionModelStatus[choice.id]
                ) {
                    Task { await prepareTranscriptionModel(choice) }
                } delete: {
                    deleteTranscriptionModel(choice)
                }
            }
            Divider()
            Picker("Language", selection: $app.settings.transcriptionLanguage) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .frame(maxWidth: 320)
            Text("Runs fully on-device (CoreML / Neural Engine). Models fetch from Hugging Face on first use — or use Download to cache and warm one up.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("models.transcription")
    }

    /// Legacy choices are hidden unless this install already uses them
    /// (selected or downloaded) — existing users keep their model and the
    /// Delete button; new users never see the superseded option.
    private var visibleTranscriptionChoices: [TranscriptionModelChoice] {
        TranscriptionModelChoice.allCases.filter { choice in
            !choice.isLegacy
                || choice == app.settings.transcriptionModel
                || downloadedTranscriptionModelIDs.contains(choice.id)
        }
    }

    private var summarizationCard: some View {
        ModelCard(icon: "brain", title: "Main LLM engine",
                  subtitle: "Used for questions, meeting summaries, and Agent Mode") {
            Picker("Backend", selection: $app.settings.summarizerBackend) {
                ForEach(AppSettings.SummarizerBackend.allCases) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            switch app.settings.summarizerBackend {
            case .builtIn:
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ModelCatalog.selectableEntries(custom: app.settings.customBuiltInModels)) { entry in
                        ModelCatalogRow(
                            entry: entry,
                            recommendedLabel: entry.id == ModelCatalog.recommendedSummarizationID
                                ? "RECOMMENDED SUMMARY" : nil)
                    }
                    Button("Browse Hugging Face…") { showingHFBrowse = true }
                        .controlSize(.small)
                    Text("Runs on the included llama.cpp server (Metal). Download the model you want from Hugging Face.")
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
                        StatusDot(color: ollamaReachable ? .green : .red)
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
        .accessibilityIdentifier("models.summarization")
    }

    private var speechCard: some View {
        ModelCard(icon: "speaker.wave.2", title: "Speech",
                  subtitle: "Read summaries and answers aloud") {
            Picker("Voice", selection: $app.settings.speechVoice) {
                ForEach(KokoroVoice.allCases) { voice in
                    Text(voice.displayName).tag(voice)
                }
            }
            .frame(maxWidth: 260)

            HStack(spacing: 10) {
                Text("Speed")
                Slider(
                    value: Binding(
                        get: { app.settings.speechSpeed },
                        set: { app.settings.speechSpeed = AppSettings.clampedSpeechSpeed($0) }),
                    in: AppSettings.minimumSpeechSpeed...AppSettings.maximumSpeechSpeed,
                    step: 0.05)
                Text("\(String(format: "%.2g", app.settings.speechSpeed))x")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            .frame(maxWidth: 320)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Kokoro 82M").font(.system(size: 12.5, weight: .medium))
                        if speechModelDownloaded {
                            Text("READY").font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.green.opacity(0.2), in: Capsule())
                        }
                    }
                    Text("Local neural TTS via sherpa-onnx. Downloads Kokoro once, then runs offline.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let speechModelError {
                        Text(speechModelError).font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer()
                if preparingSpeechModel {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let speechModelProgress {
                            ProgressView(value: speechModelProgress).frame(width: 84)
                        } else {
                            ProgressView().progressViewStyle(.linear).frame(width: 84)
                        }
                        Text(speechModelStatus ?? "Preparing...")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else if speechModelDownloaded {
                    Button("Delete") { deleteSpeechModel() }.controlSize(.mini)
                } else {
                    Button("Download") { Task { await prepareSpeechModel() } }
                        .controlSize(.small)
                }
            }
        }
        .accessibilityIdentifier("models.speech")
    }

    private var cotypingCard: some View {
        ModelCard(icon: "text.cursor", title: "Cotyping",
                  subtitle: "Inline AI autocomplete as you type") {
            CotypingModelPreparationView(compact: true)
            Picker("Cotyping model", selection: $app.settings.cotypingBuiltInModelID) {
                ForEach(ModelCatalog.selectableEntries(custom: app.settings.customBuiltInModels)) { entry in
                    Text(entry.displayName).tag(entry.id)
                }
            }
            .frame(maxWidth: 360)
            Text("Cotyping runs on a dedicated llama.cpp runtime, separate from the Main LLM engine. Gemma 4 · E4B is the recommended quality target; Qwen 3.5 2B and LFM2.5 1.2B are smaller latency options.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("models.cotyping")
    }

    private var embeddingsCard: some View {
        ModelCard(icon: "point.3.connected.trianglepath.dotted", title: "Embeddings",
                  subtitle: "Semantic search over transcripts & screenshots") {
            LabeledContent("Semantic search") {
                Text(app.settings.semanticSearchEnabled ? "On" : "Off — enable it in Ask")
                    .foregroundStyle(.secondary)
            }
            Text("Finds meetings by meaning, not just keywords. Uses Qwen3-Embedding 0.6B, downloaded when semantic search is first enabled (from Ask).")
                .font(.caption).foregroundStyle(.secondary)
            Text("Text search now uses Qwen3-Embedding 0.6B. Screenshot/slide embeddings with Qwen3-VL-Embedding 2B are listed as a future pipeline because image vectors need separate indexing and ranking.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("models.embeddings")
    }

    // MARK: - Card container

    private struct ModelCard<Content: View>: View {
        let icon: String
        let title: String
        let subtitle: String
        @ViewBuilder var content: () -> Content

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.headline)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Divider()
                content()
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
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
                                            expectedSizeGB: entry.sizeGB > 0 ? entry.sizeGB : nil,
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
        var recommendedLabel: String?

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
                        if let recommendedLabel {
                            Text(recommendedLabel).font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
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
                    Button("Delete") { downloads.delete(entry, storage: app.storage) }
                        .controlSize(.mini)
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
        let downloaded: Bool
        let ready: Bool
        let error: String?
        let progress: Double?
        let status: String?
        let prepare: () -> Void
        let delete: () -> Void

        var body: some View {
            let selected = app.settings.transcriptionModel == choice
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .onTapGesture { app.settings.transcriptionModel = choice }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(choice.displayName).font(.system(size: 12.5, weight: .medium))
                        if choice == TranscriptionModelChoice.recommended {
                            Text("RECOMMENDED").font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                        }
                        if choice.isLegacy {
                            Text("LEGACY").font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.orange.opacity(0.18), in: Capsule())
                        }
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
                } else if downloaded {
                    Button("Delete") { delete() }
                        .controlSize(.mini)
                } else {
                    Button("Download") { prepare() }
                        .controlSize(.small)
                        .disabled(prepareDisabled)
                }
            }
            .opacity(selected || downloaded || ready || preparing ? 1 : 0.75)
        }
    }

    private func refreshTranscriptionDownloads() {
        downloadedTranscriptionModelIDs = TranscriptionModelStore.downloadedChoices()
    }

    private func refreshSpeechModel() {
        speechModelDownloaded = KokoroSpeechEngine.isModelDownloaded
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
            try await choice.engine.prepare(progress: progressHandler)
            downloadedTranscriptionModelIDs.insert(choice.id)
            readyTranscriptionModelIDs.insert(choice.id)
        } catch {
            transcriptionModelErrors[choice.id] = error.localizedDescription
        }
    }

    private func deleteTranscriptionModel(_ choice: TranscriptionModelChoice) {
        do {
            try TranscriptionModelStore.delete(choice)
            downloadedTranscriptionModelIDs.remove(choice.id)
            readyTranscriptionModelIDs.remove(choice.id)
            transcriptionModelProgress[choice.id] = nil
            transcriptionModelStatus[choice.id] = nil
        } catch {
            transcriptionModelErrors[choice.id] = error.localizedDescription
        }
    }

    private func prepareSpeechModel() async {
        guard !preparingSpeechModel else { return }
        preparingSpeechModel = true
        speechModelError = nil
        speechModelStatus = "Preparing..."
        speechModelProgress = nil
        defer {
            preparingSpeechModel = false
            speechModelProgress = nil
            speechModelStatus = nil
        }
        let progressHandler: ModelPreparationProgressHandler = { update in
            speechModelProgress = update.fractionCompleted
            speechModelStatus = update.status
        }
        do {
            try await KokoroSpeechEngine.shared.prepare(progress: progressHandler)
            speechModelDownloaded = true
        } catch {
            speechModelError = error.localizedDescription
        }
    }

    private func deleteSpeechModel() {
        do {
            try KokoroSpeechEngine.deleteModel()
            speechModelDownloaded = false
            speechModelError = nil
        } catch {
            speechModelError = error.localizedDescription
        }
    }

    func testGeneration() async {
        testing = true
        testResult = nil
        defer { testing = false }
        do {
            let engine = try await app.pipeline.makeTextEngine(app.settings)
            let reply = try await engine.generate(
                system: PromptTemplates.connectivityTestSystem,
                prompt: PromptTemplates.connectivityTestPrompt,
                context: [])
            testResult = "✓ " + reply.prefix(120)
        } catch {
            testResult = "✗ \(error.localizedDescription)"
        }
    }
}
