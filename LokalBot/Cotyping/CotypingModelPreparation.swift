import Foundation

enum CotypingModelPreparationStatus: Equatable, Sendable {
    case unavailable
    case missing(ModelCatalog.Entry)
    case downloading(ModelCatalog.Entry, Double)
    case ready(ModelCatalog.Entry)
    case failed(ModelCatalog.Entry, String)

    var entry: ModelCatalog.Entry? {
        switch self {
        case .unavailable: nil
        case .missing(let entry), .downloading(let entry, _), .ready(let entry), .failed(let entry, _):
            entry
        }
    }

    var isDownloading: Bool {
        if case .downloading = self { true } else { false }
    }

    var statusText: String {
        switch self {
        case .unavailable:
            "Recommended cotyping model is not in the catalog."
        case .missing(let entry):
            "\(entry.displayName) is not downloaded yet."
        case .downloading(let entry, let progress):
            "Downloading \(entry.displayName) \(Int(progress * 100))%."
        case .ready(let entry):
            "\(entry.displayName) is downloaded."
        case .failed(let entry, let message):
            "\(entry.displayName) download failed: \(message)"
        }
    }
}

enum CotypingModelPreparationAction: Equatable, Sendable {
    case activate
    case download
    case wait
}

enum CotypingModelPreparer {
    static func recommendedEntry(custom: [ModelCatalog.Entry]) -> ModelCatalog.Entry? {
        ModelCatalog.entry(id: ModelCatalog.recommendedCotypingID, custom: custom)
    }

    static func status(
        for entry: ModelCatalog.Entry?,
        localURL: URL?,
        progress: Double?,
        error: String?
    ) -> CotypingModelPreparationStatus {
        guard let entry else { return .unavailable }
        if let progress { return .downloading(entry, max(0, min(1, progress))) }
        if let error { return .failed(entry, error) }
        if localURL != nil { return .ready(entry) }
        return .missing(entry)
    }

    @MainActor
    static func status(
        settings: AppSettings,
        storage: StorageManager,
        downloads: ModelDownloadManager
    ) -> CotypingModelPreparationStatus {
        let entry = recommendedEntry(custom: settings.customBuiltInModels)
        return status(
            for: entry,
            localURL: entry.flatMap { ModelCatalog.localURL(for: $0, storage: storage) },
            progress: entry.flatMap { downloads.progress[$0.id] },
            error: entry.flatMap { downloads.errors[$0.id] })
    }

    static func recommendedIsActive(settings: AppSettings) -> Bool {
        settings.cotypingUseSeparateModel
            && settings.cotypingBuiltInModelID == ModelCatalog.recommendedCotypingID
    }

    static func action(localURL: URL?, isDownloading: Bool) -> CotypingModelPreparationAction {
        if localURL != nil { return .activate }
        return isDownloading ? .wait : .download
    }

    @MainActor
    static func prepareRecommended(
        settings: inout AppSettings,
        storage: StorageManager,
        downloads: ModelDownloadManager
    ) {
        guard let entry = recommendedEntry(custom: settings.customBuiltInModels) else { return }
        let localURL = ModelCatalog.localURL(for: entry, storage: storage)
        switch action(localURL: localURL, isDownloading: downloads.progress[entry.id] != nil) {
        case .activate:
            settings.cotypingUseSeparateModel = true
            settings.cotypingBuiltInModelID = entry.id
        case .download:
            downloads.download(entry, storage: storage)
        case .wait:
            break
        }
    }
}
