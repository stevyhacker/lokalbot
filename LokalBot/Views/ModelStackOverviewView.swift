import SwiftUI

/// A test result is separate from model availability and is cleared when settings change.
enum ModelTestResult {
    case passed(Date)
    case failed(String)

    var label: String {
        switch self {
        case .passed(let date): "Test passed · " + date.formatted(date: .omitted, time: .shortened)
        case .failed(let message): "Test failed: \(message)"
        }
    }

    var icon: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .passed: .green
        case .failed: .orange
        }
    }
}

struct ModelStackOverviewView<Configuration: View>: View {
    @EnvironmentObject var app: AppState

    @Binding private var expandedRoles: Set<ModelRole>
    @Binding private var testResults: [ModelRole: ModelTestResult]
    private let configuration: (ModelRole) -> Configuration

    @State private var pendingPreset: ModelStackPreset?
    @Binding private var smokeTesting: Bool
    private let generationTesting: Bool
    @State private var smokeTask: Task<Void, Never>?
    @State private var testingRole: ModelRole?

    init(
        expandedRoles: Binding<Set<ModelRole>>,
        testResults: Binding<[ModelRole: ModelTestResult]>,
        smokeTesting: Binding<Bool>,
        generationTesting: Bool,
        @ViewBuilder configuration: @escaping (ModelRole) -> Configuration
    ) {
        _expandedRoles = expandedRoles
        _testResults = testResults
        _smokeTesting = smokeTesting
        self.generationTesting = generationTesting
        self.configuration = configuration
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
            coreStack
            presets
            storage
        }
        .onChange(of: app.settings) {
            smokeTask?.cancel()
            testResults = [:]
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
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    pageTitle
                    Spacer(minLength: 16)
                    testControls.fixedSize()
                }
                VStack(alignment: .leading, spacing: 12) {
                    pageTitle
                    testControls
                }
            }
            Text(testDisclosure)
                .workspaceTextRole(.supporting)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.readiness")
    }

    private var pageTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Models").font(WorkspaceTypography.pageTitle)
            Text("Choose how LokalBot transcribes, thinks, and completes text.")
                .font(WorkspaceTypography.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var testDisclosure: String {
        InferencePresentation(settings: app.settings).detail(
            local: "Tests use sample audio and text on this Mac. No private content is used.",
            remote: "Tests use sample content only. Think sends a test prompt to your approved server.")
    }

    private var testControls: some View {
        HStack {
            Button(smokeTesting ? "Testing…" : "Test models") {
                smokeTask = Task { await runSmokeTests() }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(smokeTesting || generationTesting || !snapshot.meetingReady)
            .accessibilityIdentifier("models.testAll")
            if smokeTesting { Button("Cancel test") { smokeTask?.cancel() } }
        }
    }

    private var coreStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Core roles")
                .font(WorkspaceTypography.sectionTitle)
                .padding(.bottom, 8)
            coreRow(icon: "waveform", role: .transcribe, title: "Transcribe",
                    model: app.settings.transcriptionModelDisplayName,
                    detail: "Meeting audio to transcript")
            Divider()
            coreRow(icon: "brain", role: .think, title: "Think",
                    model: app.settings.thinkModelDisplayName,
                    detail: "Summaries, Ask, and Agent")
            Divider()
            coreRow(icon: "text.cursor", role: .autocomplete, title: "Autocomplete",
                    model: autocompleteEntry?.displayName ?? "LFM2.5 1.2B Instruct",
                    detail: "Suggestions as you type")
        }
        .workspacePanel()
    }

    private func coreRow(icon: String, role: ModelRole, title: String,
                         model: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    roleHeading(icon: icon, title: title, detail: detail)
                        .frame(width: 200, alignment: .leading)
                    modelSummary(role: role, model: model)
                        .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
                    configureButton(role)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        roleHeading(icon: icon, title: title, detail: detail)
                        Spacer(minLength: 8)
                        configureButton(role)
                    }
                    modelSummary(role: role, model: model).padding(.leading, 34)
                }
            }
            if expandedRoles.contains(role) {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                    configuration(role)
                    HStack {
                        Spacer()
                        Button("Done") { expandedRoles.remove(role) }
                            .controlSize(.regular)
                            .accessibilityIdentifier("models.stack.done.\(role.rawValue)")
                    }
                }
            }
        }
        .padding(.vertical, 14)
    }

    private func roleHeading(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
                .font(.system(size: 16))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(WorkspaceTypography.rowTitle)
                Text(detail).font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func modelSummary(role: ModelRole, model: String) -> some View {
        let status = snapshot[role]
        let result = status.isReady ? testResults[role] : nil
        let destination = role == .think ? InferencePresentation(settings: app.settings) : .onDevice
        return VStack(alignment: .leading, spacing: 4) {
            Text(model).font(WorkspaceTypography.bodyEmphasis)
                .fixedSize(horizontal: false, vertical: true)
            Label(destination.label, systemImage: destination.icon)
                .font(WorkspaceTypography.metadata)
                .foregroundStyle(destination.isBlocked ? Color.orange : Color.secondary)
            Label {
                Text(testingRole == role ? "Testing…" : result?.label ?? (status.isReady ? "Configured · Not tested" : status.label))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: result?.icon ?? (status.isReady ? "circle.dotted" : "exclamationmark.circle"))
            }
            .font(WorkspaceTypography.metadata)
            .foregroundStyle(testingRole == role ? Color.secondary : result?.color ?? (status.isReady ? .secondary : .orange))
            .accessibilityIdentifier("models.stack.status.\(role.rawValue)")
        }
    }

    private func configureButton(_ role: ModelRole) -> some View {
        Button(expandedRoles.contains(role) ? "Hide settings" : "Configure…") {
            if expandedRoles.contains(role) {
                expandedRoles.remove(role)
            } else {
                expandedRoles.insert(role)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .fixedSize()
        .accessibilityIdentifier(changeButtonIdentifier(for: role))
        .accessibilityValue(expandedRoles.contains(role) ? "Expanded" : "Collapsed")
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

    private func runSmokeTests() async {
        let config = app.settings
        let savedKey = config.openAIAPIKey
        smokeTesting = true
        testResults = [:]
        defer { smokeTesting = false; testingRole = nil }

        testingRole = .transcribe
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
            try Task.checkCancellation()
            _ = try await engine.transcribe(audio: fixture, language: nil)
            guard !Task.isCancelled, config == app.settings, savedKey == app.settings.openAIAPIKey else { return }
            testResults[.transcribe] = .passed(Date())
        } catch {
            guard !Task.isCancelled, config == app.settings, savedKey == app.settings.openAIAPIKey else { return }
            testResults[.transcribe] = .failed(error.localizedDescription)
        }

        guard !Task.isCancelled, config == app.settings, savedKey == app.settings.openAIAPIKey else { return }
        testingRole = .think
        do {
            let engine = try await app.thinkExecution.makeTextEngine(
                config, priority: .interactive, purpose: "model stack smoke test")
            try Task.checkCancellation()
            _ = try await engine.generate(
                system: PromptTemplates.connectivityTestSystem,
                prompt: PromptTemplates.connectivityTestPrompt,
                context: [])
            guard !Task.isCancelled, config == app.settings, savedKey == app.settings.openAIAPIKey else { return }
            testResults[.think] = .passed(Date())
        } catch {
            guard !Task.isCancelled, config == app.settings, savedKey == app.settings.openAIAPIKey else { return }
            testResults[.think] = .failed(error.localizedDescription)
        }
        guard !Task.isCancelled, config == app.settings, savedKey == app.settings.openAIAPIKey, snapshot[.autocomplete].isReady else { return }
        testingRole = .autocomplete
        do {
            _ = try await app.cotyping.previewSuggestion(
                precedingText: "The local model stack is")
            guard !Task.isCancelled, config == app.settings, savedKey == app.settings.openAIAPIKey else { return }
            testResults[.autocomplete] = .passed(Date())
        } catch {
            guard !Task.isCancelled, config == app.settings, savedKey == app.settings.openAIAPIKey else { return }
            testResults[.autocomplete] = .failed(error.localizedDescription)
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
        self == .recommended ? TranscriptionModelChoice.recommended : .qwenASR06B
    }
    var mainModelID: String {
        self == .recommended ? ModelCatalog.defaultSummarizationID : ModelCatalog.compactFallbackID
    }
    var autocompleteModelID: String { ModelCatalog.recommendedCotypingID }
    var modelLine: String {
        self == .recommended
            ? "\(transcription.displayName) · Qwen3.5 4B · LFM2.5 1.2B"
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
