import SwiftUI

struct ModelStackOverviewView<Configuration: View>: View {
    @EnvironmentObject var app: AppState

    @Binding private var expandedRoles: Set<ModelRole>
    private let configuration: Configuration

    @State private var pendingPreset: ModelStackPreset?
    @State private var smokeTesting = false
    @State private var smokeTask: Task<Void, Never>?
    @State private var smokeResults: [String: String] = [:]

    init(
        expandedRoles: Binding<Set<ModelRole>>,
        @ViewBuilder configuration: () -> Configuration
    ) {
        _expandedRoles = expandedRoles
        self.configuration = configuration()
    }

    private var autocompleteEntry: ModelCatalog.Entry? {
        ModelCatalog.entry(id: app.settings.cotypingBuiltInModelID,
                           custom: app.settings.customBuiltInModels)
    }
    private var snapshot: ModelRolesSnapshot {
#if LOKALBOT_UI_TEST_HOST
        if ProcessInfo.processInfo.environment["LOKALBOT_MODELS_DEMO_READY"] == "1" {
            return ModelRolesSnapshot(
                readiness: .init(
                    transcriptionReady: true,
                    thinkReady: true,
                    autocompleteReady: true,
                    provenance: .local,
                    storedBytes: 7_900_000_000,
                    availableBytes: 128_000_000_000,
                    activeDownloads: 0,
                    failedDownloads: 0),
                statuses: Dictionary(
                    uniqueKeysWithValues: ModelRole.allCases.map { ($0, .ready) }))
        }
#endif
        return app.modelRoles.snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            readinessBanner
            InferenceDisclosure(settings: app.settings,
                localText: "Tests use a synthetic audio tone and a fixed prompt on this Mac. Ready means available; Passed is a separate test result.",
                remoteText: "The test sends a fixed synthetic prompt to your approved server. It does not include private content. Ready and Passed are separate states.")
            coreStack
            if !expandedRoles.isEmpty {
                configuration
            }
            presets
            storage
        }
        .onChange(of: app.settings) {
            smokeTask?.cancel()
            smokeResults = [:]
        }
        .onDisappear { smokeTask?.cancel() }
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
            Image(systemName: readinessIcon)
                .font(.title2)
                .foregroundStyle(readinessColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.meetingReady ? "Meeting models ready" : snapshot.headline)
                    .font(WorkspaceTypography.sectionTitle)
                Text(snapshot.detail)
                    .font(WorkspaceTypography.body).foregroundStyle(.secondary)
            }
            Spacer()
            Button(smokeTesting ? "Testing..." : "Test configured models") {
                smokeTask = Task { await runSmokeTests() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(smokeTesting || !snapshot.meetingReady)
            if smokeTesting { Button("Cancel test") { smokeTask?.cancel() } }
        }
        .workspacePanel()
        .accessibilityIdentifier("models.readiness")
    }

    private var coreStack: some View {
        WorkspaceSection(title: "Core roles", icon: "square.stack.3d.up") {
            coreRow(
                icon: "waveform",
                stackRole: .transcribe,
                role: "Transcribe",
                model: app.settings.transcriptionModelDisplayName,
                detail: "Meeting audio to cited transcript",
                status: snapshot[.transcribe],
                result: smokeResults["Transcribe"])
            Divider()
            coreRow(
                icon: "brain",
                stackRole: .think,
                role: "Think",
                model: app.settings.thinkModelDisplayName,
                detail: "Summaries, Ask, outcomes, and Agent",
                status: snapshot[.think],
                result: smokeResults["Think"])
            Divider()
            coreRow(
                icon: "text.cursor",
                stackRole: .autocomplete,
                role: "Autocomplete",
                model: autocompleteEntry?.displayName ?? "LFM2.5 1.2B Instruct",
                detail: "Low-latency writing completion",
                status: snapshot[.autocomplete],
                result: smokeResults["Autocomplete"])
        }
    }

    private func coreRow(icon: String, stackRole: ModelRole, role: String,
                         model: String, detail: String, status: ModelRoleStatus,
                         result: String?) -> some View {
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
                    StatusDot(color: roleColor(status), size: 7)
                    Text(result ?? status.label)
                        .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
                }
            }
            Button(expandedRoles.contains(stackRole) ? "Done" : "Change…") {
                toggle(stackRole)
            }
            .controlSize(.small)
            .accessibilityIdentifier(changeButtonIdentifier(for: stackRole))
        }
        .padding(.vertical, 8)
    }

    private func toggle(_ role: ModelRole) {
        if expandedRoles.contains(role) {
            expandedRoles.remove(role)
        } else {
            expandedRoles.insert(role)
        }
    }

    private func changeButtonIdentifier(for role: ModelRole) -> String {
        // Keep the established UI automation contract while the product term
        // and domain role use the clearer Autocomplete name.
        let suffix = role == .autocomplete ? "type" : role.rawValue
        return "models.stack.change.\(suffix)"
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
        app.modelRoles.startCoreModelDownloads()
    }

    private var readinessIcon: String {
        switch snapshot.primaryActionStatus {
        case .ready: "checkmark.seal.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .downloading, .preparing: "arrow.down.circle.fill"
        case .unavailable: "arrow.down.circle"
        }
    }

    private var readinessColor: Color {
        switch snapshot.primaryActionStatus {
        case .ready: .green
        case .needsAttention: Brand.error
        case .downloading, .preparing, .unavailable: Brand.teal
        }
    }

    private func roleColor(_ status: ModelRoleStatus) -> Color {
        switch status {
        case .ready: .green
        case .needsAttention: Brand.error
        case .downloading, .preparing, .unavailable: .orange
        }
    }

    private func runSmokeTests() async {
        let config = app.settings
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
            let engine = config.transcriptionEngine()
            try await engine.prepare()
            _ = try await engine.transcribe(audio: fixture, language: nil)
            guard !Task.isCancelled, config == app.settings else { return }
            smokeResults["Transcribe"] = "Passed · " + Date().formatted(date: .omitted, time: .shortened)
        } catch {
            guard !Task.isCancelled, config == app.settings else { return }
            smokeResults["Transcribe"] = "Failed: \(error.localizedDescription)"
        }

        do {
            let engine = try await app.thinkExecution.makeTextEngine(
                config, priority: .interactive, purpose: "model stack smoke test")
            _ = try await engine.generate(
                system: PromptTemplates.connectivityTestSystem,
                prompt: PromptTemplates.connectivityTestPrompt,
                context: [])
            guard !Task.isCancelled, config == app.settings else { return }
            smokeResults["Think"] = "Passed · " + Date().formatted(date: .omitted, time: .shortened)
        } catch {
            guard !Task.isCancelled, config == app.settings else { return }
            smokeResults["Think"] = "Failed: \(error.localizedDescription)"
        }
        guard snapshot[.autocomplete].isReady else { return }
        do {
            _ = try await app.cotyping.previewSuggestion(
                precedingText: "The local model stack is")
            guard !Task.isCancelled, config == app.settings else { return }
            smokeResults["Autocomplete"] = "Passed · " + Date().formatted(date: .omitted, time: .shortened)
        } catch {
            guard !Task.isCancelled, config == app.settings else { return }
            smokeResults["Autocomplete"] = "Failed: \(error.localizedDescription)"
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
        let currentMain = app.settings.thinkModelDisplayName
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
            + "Autocomplete: \(nextAutocomplete)\nEstimated new GGUF download: \(size), plus the selected speech model if missing. Existing models are kept."
    }
}
