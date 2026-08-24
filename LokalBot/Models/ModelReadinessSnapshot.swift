import Foundation

/// One honest, UI-ready view of the selected model stack. Core readiness is
/// limited to Transcribe, Think, and Autocomplete; optional Voice/Embeddings
/// never make the main stack fail.
struct ModelReadinessSnapshot: Equatable, Sendable {
    enum Provenance: Equatable, Sendable {
        case local
        case externalThink(String)
    }

    var transcriptionReady: Bool
    var thinkReady: Bool
    var autocompleteReady: Bool
    var provenance: Provenance
    var storedBytes: Int64
    var availableBytes: Int64?
    var activeDownloads: Int
    var failedDownloads: Int

    var coreReady: Bool {
        transcriptionReady && thinkReady && autocompleteReady
    }

    var headline: String {
        if coreReady {
            switch provenance {
            case .local: "Ready on this Mac"
            case .externalThink: "Core stack configured"
            }
        } else {
            "Finish preparing this Mac"
        }
    }

    var detail: String {
        if coreReady {
            switch provenance {
            case .local:
                return "Transcribe, Think, and Autocomplete are available locally."
            case .externalThink(let name):
                return "Transcribe and Autocomplete are local. Think uses \(name)."
            }
        } else if activeDownloads > 0 {
            return "\(activeDownloads) selected model download\(activeDownloads == 1 ? " is" : "s are") in progress."
        } else if failedDownloads > 0 {
            return "A selected model needs attention before the stack is ready."
        } else {
            return "Missing models stay staged locally and download only after confirmation."
        }
    }

    var storageSummary: String {
        let stored = ByteCountFormatter.string(fromByteCount: storedBytes, countStyle: .file)
        guard let availableBytes else { return "\(stored) stored locally" }
        let free = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
        return "\(stored) stored locally · \(free) available"
    }

    // MARK: Role readiness (shared by automation gates)

    /// True when the selected meeting-transcription model is fully on disk.
    /// Automation (auto-processing, prewarm) must consult this before running:
    /// a missing model means a multi-gigabyte download the user never asked
    /// for at that moment.
    static func transcriptionReady(_ settings: AppSettings) -> Bool {
        TranscriptionModelStore.isDownloaded(
            settings.transcriptionModel,
            graniteConfiguration: settings.graniteSpeechModel)
    }

    /// True when the Think role can run without triggering a model download.
    /// Remote backends are always "ready" — their approval flow is separate.
    static func thinkReady(_ settings: AppSettings, storage: StorageManager) -> Bool {
        guard settings.summarizerBackend == .builtIn else { return true }
        guard let entry = ModelCatalog.entry(
            id: settings.builtInModelID,
            custom: settings.customBuiltInModels) else { return false }
        return ModelCatalog.localURL(for: entry, storage: storage) != nil
    }

    static func autocompleteReady(_ settings: AppSettings, storage: StorageManager) -> Bool {
        guard let entry = ModelCatalog.entry(
            id: settings.cotypingBuiltInModelID,
            custom: settings.customBuiltInModels) else { return false }
        return ModelCatalog.localURL(for: entry, storage: storage) != nil
    }

    /// Settings that can change whether a parked meeting may transcribe or
    /// summarize without downloading anything. AppState uses this to re-check
    /// parked work immediately after a selection change.
    static func processingReadinessChanged(from old: AppSettings,
                                           to new: AppSettings) -> Bool {
        old.transcriptionModel != new.transcriptionModel
            || old.graniteSpeechModel != new.graniteSpeechModel
            || old.summarizerBackend != new.summarizerBackend
            || old.builtInModelID != new.builtInModelID
            || old.customBuiltInModels != new.customBuiltInModels
    }

    /// Total bytes of the core GGUF models (Think when built-in, Autocomplete)
    /// still missing on disk. The Transcribe model downloads through its
    /// engine-specific path and is not included — callers name it separately.
    static func missingCoreModelBytes(_ settings: AppSettings, storage: StorageManager) -> Int64 {
        var ids = [settings.cotypingBuiltInModelID]
        if settings.summarizerBackend == .builtIn { ids.append(settings.builtInModelID) }
        return ids.compactMap {
            ModelCatalog.entry(id: $0, custom: settings.customBuiltInModels)
        }.filter {
            ModelCatalog.localURL(for: $0, storage: storage) == nil
        }.reduce(Int64(0)) { $0 + Int64($1.sizeBytes ?? 0) }
    }

    static func make(
        settings: AppSettings,
        storage: StorageManager,
        activeDownloads: Int,
        failedDownloads: Int
    ) -> Self {
        let transcriptionReady = transcriptionReady(settings)
        let thinkReady = thinkReady(settings, storage: storage)
        let autocompleteReady = autocompleteReady(settings, storage: storage)
        let provenance: Provenance = settings.summarizerBackend == .builtIn
            ? .local : .externalThink(settings.summarizerBackend.displayName)
        let modelsFolder = storage.rootURL.appendingPathComponent("models", isDirectory: true)
        return Self(
            transcriptionReady: transcriptionReady,
            thinkReady: thinkReady,
            autocompleteReady: autocompleteReady,
            provenance: provenance,
            storedBytes: directoryBytes(modelsFolder),
            availableBytes: DiskSpacePrecheck.availableBytes(at: modelsFolder),
            activeDownloads: activeDownloads,
            failedDownloads: failedDownloads)
    }

    private static func directoryBytes(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
