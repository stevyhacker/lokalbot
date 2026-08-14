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

    @MainActor
    static func make(app: AppState, downloads: ModelDownloadManager) -> Self {
        let settings = app.settings
        let mainEntry = ModelCatalog.entry(
            id: settings.builtInModelID,
            custom: settings.customBuiltInModels)
        let autocompleteEntry = ModelCatalog.entry(
            id: settings.cotypingBuiltInModelID,
            custom: settings.customBuiltInModels)
        let transcriptionReady = TranscriptionModelStore.isDownloaded(
            settings.transcriptionModel,
            graniteConfiguration: settings.graniteSpeechModel)
        let thinkReady = settings.summarizerBackend == .builtIn
            ? mainEntry.flatMap { ModelCatalog.localURL(for: $0, storage: app.storage) } != nil
            : true
        let autocompleteReady = autocompleteEntry.flatMap {
            ModelCatalog.localURL(for: $0, storage: app.storage)
        } != nil
        let provenance: Provenance = settings.summarizerBackend == .builtIn
            ? .local : .externalThink(settings.summarizerBackend.displayName)
        let modelsFolder = app.storage.rootURL.appendingPathComponent("models", isDirectory: true)
        return Self(
            transcriptionReady: transcriptionReady,
            thinkReady: thinkReady,
            autocompleteReady: autocompleteReady,
            provenance: provenance,
            storedBytes: directoryBytes(modelsFolder),
            availableBytes: DiskSpacePrecheck.availableBytes(at: modelsFolder),
            activeDownloads: downloads.progress.count,
            failedDownloads: downloads.errors.values.filter { !$0.isEmpty }.count)
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
