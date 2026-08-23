import Combine
import Foundation

enum ModelRole: String, CaseIterable, Hashable, Sendable {
    case transcribe
    case think
    case autocomplete
}

enum ModelRoleStatus: Equatable, Sendable {
    case unavailable
    case downloading(progress: Double?)
    case preparing(progress: Double?, label: String)
    case ready
    case needsAttention(String)

    var isReady: Bool { self == .ready }

    var isWorking: Bool {
        switch self {
        case .downloading, .preparing: true
        case .unavailable, .ready, .needsAttention: false
        }
    }

    var progress: Double? {
        switch self {
        case .downloading(let progress), .preparing(let progress, _): progress
        case .unavailable, .ready, .needsAttention: nil
        }
    }

    var errorMessage: String? {
        if case .needsAttention(let message) = self { return message }
        return nil
    }

    var label: String {
        switch self {
        case .unavailable:
            "Download required"
        case .downloading(let progress):
            progress.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading…"
        case .preparing(_, let label):
            label
        case .ready:
            "Ready"
        case .needsAttention:
            "Needs attention"
        }
    }
}

struct ModelRolesSnapshot: Equatable, Sendable {
    var readiness: ModelReadinessSnapshot
    var statuses: [ModelRole: ModelRoleStatus]

    subscript(_ role: ModelRole) -> ModelRoleStatus {
        statuses[role] ?? .unavailable
    }

    var coreReady: Bool { ModelRole.allCases.allSatisfy { self[$0].isReady } }
    var headline: String { readiness.headline }
    var storageSummary: String { readiness.storageSummary }
    var activeDownloads: Int { readiness.activeDownloads }
    var failedDownloads: Int { readiness.failedDownloads }

    var detail: String {
        if coreReady { return readiness.detail }
        if let working = ModelRole.allCases.lazy.map({ self[$0] }).first(where: \.isWorking) {
            return working.label
        }
        if ModelRole.allCases.contains(where: { self[$0].errorMessage != nil }) {
            return "A selected model needs attention before the stack is ready."
        }
        return readiness.detail
    }

    var primaryActionStatus: ModelRoleStatus {
        if coreReady { return .ready }
        if let error = ModelRole.allCases.lazy.compactMap({ self[$0].errorMessage }).first {
            return .needsAttention(error)
        }
        if let working = ModelRole.allCases.lazy.map({ self[$0] }).first(where: \.isWorking) {
            return working
        }
        return .unavailable
    }
}

/// Owns selection readiness, model preparation, progress, failures, and the
/// wake-up signal for work parked behind missing models. Onboarding, Settings,
/// and automation all read the same role lifecycle through this interface.
@MainActor
final class ModelRoles: ObservableObject {
    struct TranscriptionPreparation: Equatable, Sendable {
        var progress: Double?
        var label: String
    }

    typealias PrepareTranscription = @MainActor (
        AppSettings,
        TranscriptionModelChoice,
        ModelPreparationProgressHandler?
    ) async throws -> Void

    @Published private(set) var downloadProgress: [String: Double]
    @Published private(set) var downloadErrors: [String: String]
    @Published private(set) var transcriptionPreparations: [String: TranscriptionPreparation] = [:]
    @Published private(set) var transcriptionErrors: [String: String] = [:]
    @Published private(set) var revision = 0

    private let settings: () -> AppSettings
    private let storage: StorageManager
    private let downloads: ModelDownloadManager
    private let prepareTranscription: PrepareTranscription
    private let onReadinessChanged: () -> Void
    private var downloadObserver: AnyCancellable?
    private var preparationTask: (id: String, token: UUID, task: Task<Void, Never>)?

    init(
        settings: @escaping () -> AppSettings,
        storage: StorageManager,
        downloads: ModelDownloadManager? = nil,
        prepareTranscription: PrepareTranscription? = nil,
        onReadinessChanged: @escaping () -> Void
    ) {
        let downloads = downloads ?? ModelDownloadManager.shared
        self.settings = settings
        self.storage = storage
        self.downloads = downloads
        self.downloadProgress = downloads.progress
        self.downloadErrors = downloads.errors
        self.prepareTranscription = prepareTranscription ?? { settings, choice, progress in
            try await settings.transcriptionEngine(for: choice).prepare(progress: progress)
        }
        self.onReadinessChanged = onReadinessChanged
        downloadObserver = downloads.$progress
            .combineLatest(downloads.$errors)
            .dropFirst()
            .sink { [weak self] progress, errors in
                guard let self else { return }
                let completedDownloads = !self.downloadProgress.isEmpty && progress.isEmpty
                self.downloadProgress = progress
                self.downloadErrors = errors
                self.revision &+= 1
                if completedDownloads { self.onReadinessChanged() }
            }
    }

    var snapshot: ModelRolesSnapshot {
        let settings = settings()
        let readiness = ModelReadinessSnapshot.make(
            settings: settings,
            storage: storage,
            activeDownloads: downloadProgress.count,
            failedDownloads: downloadErrors.values.filter { !$0.isEmpty }.count)
        return ModelRolesSnapshot(
            readiness: readiness,
            statuses: [
                .transcribe: transcriptionStatus(for: settings.transcriptionModel),
                .think: ggufStatus(
                    ready: readiness.thinkReady,
                    id: settings.summarizerBackend == .builtIn
                        ? settings.builtInModelID : nil),
                .autocomplete: ggufStatus(
                    ready: readiness.autocompleteReady,
                    id: settings.cotypingBuiltInModelID),
            ])
    }

    var downloadedTranscriptionModelIDs: Set<String> {
        TranscriptionModelStore.downloadedChoices(
            graniteConfiguration: settings().graniteSpeechModel)
    }

    var isPreparingTranscription: Bool { preparationTask != nil }

    func transcriptionStatus(for choice: TranscriptionModelChoice) -> ModelRoleStatus {
        if let preparation = transcriptionPreparations[choice.id] {
            return .preparing(progress: preparation.progress, label: preparation.label)
        }
        if let error = transcriptionErrors[choice.id], !error.isEmpty {
            return .needsAttention(error)
        }
        return downloadedTranscriptionModelIDs.contains(choice.id) ? .ready : .unavailable
    }

    func settingsDidChange(from old: AppSettings, to new: AppSettings) {
        guard ModelReadinessSnapshot.processingReadinessChanged(from: old, to: new)
                || old.cotypingBuiltInModelID != new.cotypingBuiltInModelID else { return }
        if old.transcriptionModel != new.transcriptionModel
            || old.graniteSpeechModel != new.graniteSpeechModel {
            cancelPreparation()
        }
        revision &+= 1
        onReadinessChanged()
    }

    func readinessDidChange() {
        revision &+= 1
        onReadinessChanged()
    }

    func startCoreModelDownloads() {
        let settings = settings()
        var ids = [settings.cotypingBuiltInModelID]
        if settings.summarizerBackend == .builtIn { ids.append(settings.builtInModelID) }
        for id in ids {
            guard let entry = ModelCatalog.entry(
                id: id,
                custom: settings.customBuiltInModels),
                ModelCatalog.localURL(for: entry, storage: storage) == nil else { continue }
            downloads.download(entry, storage: storage)
        }
        if ModelReadinessSnapshot.transcriptionReady(settings) {
            cancelPreparation()
            readinessDidChange()
        } else {
            prepareTranscriptionModel(settings.transcriptionModel)
        }
    }

    func prepareTranscriptionModel(_ choice: TranscriptionModelChoice) {
        guard preparationTask == nil else { return }
        let configuration = settings()
        let token = UUID()
        transcriptionErrors[choice.id] = nil
        transcriptionPreparations[choice.id] = .init(
            progress: nil,
            label: "Preparing…")
        let task = Task { [weak self] in
            guard let self else { return }
            let failure: String?
            do {
                try await self.prepareTranscription(configuration, choice) { [weak self] update in
                    guard let self,
                          self.preparationTask?.token == token else { return }
                    self.transcriptionPreparations[choice.id] = .init(
                        progress: update.fractionCompleted,
                        label: update.status)
                }
                failure = nil
            } catch is CancellationError {
                return
            } catch {
                let displayName = choice == .graniteSpeech
                    ? configuration.graniteSpeechModel.displayName
                    : choice.displayName
                failure = "Could not prepare \(displayName): \(error.localizedDescription)"
            }
            guard self.preparationTask?.token == token else { return }
            self.preparationTask = nil
            self.transcriptionPreparations[choice.id] = nil
            self.transcriptionErrors[choice.id] = failure
            self.readinessDidChange()
        }
        preparationTask = (choice.id, token, task)
    }

    func deleteTranscriptionModel(_ choice: TranscriptionModelChoice) {
        if preparationTask?.id == choice.id { cancelPreparation() }
        do {
            try TranscriptionModelStore.delete(
                choice,
                graniteConfiguration: settings().graniteSpeechModel)
            transcriptionErrors[choice.id] = nil
            readinessDidChange()
        } catch {
            transcriptionErrors[choice.id] = error.localizedDescription
        }
    }

    private func ggufStatus(ready: Bool, id: String?) -> ModelRoleStatus {
        if ready { return .ready }
        guard let id else { return .unavailable }
        if let progress = downloadProgress[id] { return .downloading(progress: progress) }
        if let error = downloadErrors[id], !error.isEmpty { return .needsAttention(error) }
        return .unavailable
    }

    private func cancelPreparation() {
        guard let preparationTask else { return }
        preparationTask.task.cancel()
        transcriptionPreparations[preparationTask.id] = nil
        self.preparationTask = nil
    }
}
