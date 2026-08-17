import SwiftUI

struct ModelStackOverviewView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var downloads = ModelDownloadManager.shared

    @State private var pendingPreset: ModelStackPreset?
    @State private var smokeTesting = false
    @State private var smokeResults: [String: String] = [:]

    private var mainEntry: ModelCatalog.Entry? {
        ModelCatalog.entry(id: app.settings.builtInModelID,
                           custom: app.settings.customBuiltInModels)
    }
    private var autocompleteEntry: ModelCatalog.Entry? {
        ModelCatalog.entry(id: app.settings.cotypingBuiltInModelID,
                           custom: app.settings.customBuiltInModels)
    }
    private var snapshot: ModelReadinessSnapshot {
#if LOKALBOT_UI_TEST_HOST
        if ProcessInfo.processInfo.environment["LOKALBOT_MODELS_DEMO_READY"] == "1" {
            return .init(
                transcriptionReady: true, thinkReady: true, autocompleteReady: true,
                provenance: .local, storedBytes: 7_900_000_000,
                availableBytes: 128_000_000_000, activeDownloads: 0, failedDownloads: 0)
        }
#endif
        return .make(app: app, downloads: downloads)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            readinessBanner
            coreStack
            presets
            storage
            optionalModels
        }
        .confirmationDialog(
            pendingPreset.map { "Apply \($0.title) preset?" } ?? "Apply preset?",
            isPresented: Binding(
                get: { pendingPreset != nil },
                set: { if !$0 { pendingPreset = nil } })) {
            if let pendingPreset {
                Button("Apply and stage downloads") { apply(pendingPreset) }
                Button("Cancel", role: .cancel) { self.pendingPreset = nil }
            }
        } message: {
            if let pendingPreset {
                Text(pendingPreset.changeSummary(app: app))
            }
        }
    }

    private var readinessBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: snapshot.coreReady ? "checkmark.seal.fill" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(snapshot.coreReady ? .green : Brand.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.headline)
                    .font(WorkspaceTypography.sectionTitle)
                Text(snapshot.detail)
                    .font(WorkspaceTypography.body).foregroundStyle(.secondary)
            }
            Spacer()
            Button(smokeTesting ? "Testing..." : "Test local stack") {
                Task { await runSmokeTests() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(smokeTesting || !snapshot.coreReady)
        }
        .workspacePanel()
        .accessibilityIdentifier("models.readiness")
    }

    private var coreStack: some View {
        WorkspaceSection(title: "Core roles", icon: "square.stack.3d.up") {
            coreRow(
                icon: "waveform",
                role: "Transcribe",
                model: app.settings.transcriptionModelDisplayName,
                detail: "Meeting audio to cited transcript",
                ready: snapshot.transcriptionReady,
                result: smokeResults["Transcribe"])
            Divider()
            coreRow(
                icon: "brain",
                role: "Think",
                model: mainEntry?.displayName ?? app.settings.summarizerBackend.displayName,
                detail: "Summaries, Ask, outcomes, and Agent",
                ready: snapshot.thinkReady,
                result: smokeResults["Think"])
            Divider()
            coreRow(
                icon: "text.cursor",
                role: "Autocomplete",
                model: autocompleteEntry?.displayName ?? "LFM2.5 1.2B Instruct",
                detail: "Low-latency writing completion",
                ready: snapshot.autocompleteReady,
                result: smokeResults["Autocomplete"])
        }
    }

    private func coreRow(icon: String, role: String, model: String, detail: String,
                         ready: Bool, result: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Brand.teal).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(role).font(WorkspaceTypography.rowTitle)
                Text(detail).font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(model).font(WorkspaceTypography.rowTitle).lineLimit(1)
                HStack(spacing: 5) {
                    StatusDot(color: ready ? .green : .orange, size: 7)
                    Text(result ?? (ready ? "Ready" : "Download required"))
                        .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var presets: some View {
        WorkspaceSection(title: "Presets", icon: "slider.horizontal.3") {
            HStack(spacing: 12) {
                ForEach(ModelStackPreset.allCases) { preset in
                    Button {
                        pendingPreset = preset
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(preset.title).font(WorkspaceTypography.rowTitle)
                            Text(preset.subtitle).font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
                            Text(preset.modelLine)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary.opacity(0.25),
                                    in: RoundedRectangle(cornerRadius: Brand.Radius.control))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("models.preset.\(preset.rawValue)")
                }
            }
            Text("Preset changes always show the exact role changes and estimated local download before applying.")
                .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
        }
    }

    private var optionalModels: some View {
        WorkspaceSection(title: "Optional", icon: "plus.circle") {
            HStack {
                Label("Voice", systemImage: "speaker.wave.2")
                Spacer()
                Text(KokoroSpeechEngine.isModelDownloaded ? "Ready" : "Not downloaded")
                    .foregroundStyle(.secondary)
                Divider().frame(height: 24)
                Label("Embeddings", systemImage: "point.3.connected.trianglepath.dotted")
                Spacer()
                Text(app.embeddingIndex.hasEmbeddings ? "Indexed" : "Optional")
                    .foregroundStyle(.secondary)
            }
            .font(WorkspaceTypography.body)
        }
    }

    private var storage: some View {
        WorkspaceSection(title: "Model storage", icon: "internaldrive") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.storageSummary).font(WorkspaceTypography.rowTitle)
                    Text(snapshot.activeDownloads == 0
                         ? "No model downloads in progress"
                         : "\(snapshot.activeDownloads) download\(snapshot.activeDownloads == 1 ? "" : "s") in progress")
                        .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
                }
                Spacer()
                if snapshot.failedDownloads > 0 {
                    Label("\(snapshot.failedDownloads) failed", systemImage: "exclamationmark.triangle")
                        .font(WorkspaceTypography.metadata).foregroundStyle(Brand.error)
                } else {
                    Label("Downloads verified on completion", systemImage: "checkmark.shield")
                        .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("models.storage")
    }

    private func apply(_ preset: ModelStackPreset) {
        pendingPreset = nil
        app.settings.transcriptionModel = preset.transcription
        app.settings.summarizerBackend = .builtIn
        app.settings.builtInModelID = preset.mainModelID
        app.settings.cotypingBuiltInModelID = preset.autocompleteModelID
        // Shared kickoff also re-checks meetings parked as "waiting for
        // models" once the downloads land.
        app.startCoreModelDownloads()
    }

    private func runSmokeTests() async {
        smokeTesting = true
        smokeResults = [:]
        defer { smokeTesting = false }

        do {
            let fixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("lokalbot-model-smoke-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: fixture) }
            let samples = (0..<16_000).map { index in
                Float(sin(Double(index) / 16_000 * 440 * 2 * .pi) * 0.02)
            }
            try OnnxTranscriptionEngine.writeWav(samples, to: fixture)
            let engine = app.settings.transcriptionEngine()
            try await engine.prepare()
            _ = try await engine.transcribe(audio: fixture, language: nil)
            smokeResults["Transcribe"] = "Passed"
        } catch {
            smokeResults["Transcribe"] = "Failed"
        }

        do {
            let engine = try await app.pipeline.makeTextEngine(
                app.settings, priority: .interactive, purpose: "model stack smoke test")
            _ = try await engine.generate(
                system: PromptTemplates.connectivityTestSystem,
                prompt: PromptTemplates.connectivityTestPrompt,
                context: [])
            smokeResults["Think"] = "Passed"
        } catch {
            smokeResults["Think"] = "Failed"
        }

        do {
            _ = try await app.cotyping.previewSuggestion(
                precedingText: "The local model stack is")
            smokeResults["Autocomplete"] = "Passed"
        } catch {
            smokeResults["Autocomplete"] = "Failed"
        }
    }
}

enum ModelStackPreset: String, CaseIterable, Identifiable {
    case recommended
    case lightweight

    var id: String { rawValue }
    var title: String { self == .recommended ? "Recommended" : "Lightweight" }
    var subtitle: String {
        self == .recommended
            ? "Best balanced local stack" : "Smallest practical local stack"
    }
    var transcription: TranscriptionModelChoice {
        self == .recommended ? .graniteSpeech : .qwenASR06B
    }
    var mainModelID: String {
        self == .recommended ? ModelCatalog.defaultSummarizationID : ModelCatalog.compactFallbackID
    }
    var autocompleteModelID: String { ModelCatalog.recommendedCotypingID }
    var modelLine: String {
        self == .recommended
            ? "Granite Speech 4.1 2B · Qwen3.5 4B · LFM2.5 1.2B"
            : "Qwen3-ASR 0.6B · Qwen3.5 0.8B · LFM2.5 1.2B"
    }

    @MainActor
    func changeSummary(app: AppState) -> String {
        let currentMain = ModelCatalog.entry(
            id: app.settings.builtInModelID,
            custom: app.settings.customBuiltInModels)?.displayName
            ?? app.settings.builtInModelID
        let nextMain = ModelCatalog.entry(
            id: mainModelID,
            custom: app.settings.customBuiltInModels)?.displayName ?? mainModelID
        let nextAutocomplete = ModelCatalog.entry(
            id: autocompleteModelID,
            custom: app.settings.customBuiltInModels)?.displayName ?? autocompleteModelID
        let missingBytes = [mainModelID, autocompleteModelID].compactMap {
            ModelCatalog.entry(id: $0, custom: app.settings.customBuiltInModels)
        }.filter {
            ModelCatalog.localURL(for: $0, storage: app.storage) == nil
        }.reduce(Int64(0)) { $0 + Int64($1.sizeBytes ?? 0) }
        let size = ByteCountFormatter.string(fromByteCount: missingBytes, countStyle: .file)
        return "Transcribe: \(app.settings.transcriptionModelDisplayName) -> \(transcription.displayName)\n"
            + "Think: \(currentMain) -> \(nextMain)\n"
            + "Autocomplete: \(nextAutocomplete)\nEstimated new download: \(size)."
    }
}
