import Foundation

/// Built-in LLM backend, part 2 of 3: model download orchestration. Validated,
/// staged downloads of catalog (and, via `download(url:fileName:id:)`, arbitrary
/// Hugging Face) GGUF models into <storage>/models/. One download path:
/// `ParallelRangeDownloader` (which falls back to a streamed single GET
/// internally), then validate + atomically install.
@MainActor
final class ModelDownloadManager: ObservableObject {

    static let shared = ModelDownloadManager()

    @Published private(set) var progress: [String: Double] = [:]   // entry id → 0…1
    @Published private(set) var errors: [String: String] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]
    private var lastProgressPublish: [String: (fraction: Double, time: TimeInterval)] = [:]

    private let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = ParallelRangeDownloader.defaultMaxConcurrentParts
        configuration.networkServiceType = .responsiveData
        configuration.httpShouldSetCookies = false
        return configuration
    }())

    func download(_ entry: ModelCatalog.Entry, storage: StorageManager) {
        download(url: entry.url, fileName: entry.fileName, id: entry.id,
                 expectedSizeGB: entry.sizeGB, storage: storage)
    }

    /// Generic GGUF download keyed by an arbitrary id (catalog id, or a Hugging
    /// Face "<repo>/<file>" key for browsed models). Idempotent per id.
    /// `expectedSizeGB` (when known) gates the download on free disk space up
    /// front instead of failing after gigabytes have moved.
    func download(url urlString: String, fileName: String, id: String,
                  expectedSizeGB: Double? = nil, storage: StorageManager) {
        guard tasks[id] == nil, let url = URL(string: urlString) else { return }
        let folder = storage.rootURL.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(fileName)
        // Resume stash inside the models folder (not the system temp dir):
        // it's on the same volume as the final install and macOS won't reap a
        // half-finished 17 GB download between attempts.
        let stashDirectory = folder.appendingPathComponent(".partial", isDirectory: true)
        // Credit bytes an interrupted attempt already stashed: a retry only
        // fetches the remainder (and an invalidated stash is deleted first,
        // freeing the same bytes), so requiring the full size again would
        // refuse resumes that fit fine.
        let stashedBytes = ParallelRangeDownloader.stashedByteCount(
            for: url, stashDirectory: stashDirectory)
        if let advisory = DiskSpacePrecheck.advisory(
            expectedBytes: expectedSizeGB.map { max(0, Int64($0 * 1_000_000_000) - stashedBytes) },
            availableBytes: DiskSpacePrecheck.availableBytes(at: folder)) {
            errors[id] = advisory
            return
        }
        progress[id] = 0
        errors[id] = nil
        let session = session
        tasks[id] = Task(priority: .utility) { [weak self] in
            do {
                let stashed = try await ParallelRangeDownloader.download(
                    from: url, session: session, stashDirectory: stashDirectory) { update in
                    Task { @MainActor [weak self] in
                        self?.publishProgress(id: id, fraction: update.fractionCompleted)
                    }
                }
                self?.finish(id: id, destination: destination, stashed: stashed)
            } catch {
                self?.fail(id: id, error: error)
            }
        }
    }

    func cancel(_ entry: ModelCatalog.Entry) { cancel(id: entry.id) }

    func cancel(id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        progress[id] = nil
        lastProgressPublish[id] = nil
    }

    func delete(_ entry: ModelCatalog.Entry, storage: StorageManager) {
        try? FileManager.default.removeItem(
            at: storage.rootURL.appendingPathComponent("models/\(entry.fileName)"))
        objectWillChange.send()
    }

    private func finish(id: String, destination: URL, stashed: URL) {
        defer {
            tasks[id] = nil
            progress[id] = nil
            lastProgressPublish[id] = nil
        }

        let looksGGUF = ModelFileValidator.looksLikeGGUF(stashed)
        let outcome = DownloadOutcomeClassifier.classify(
            httpStatus: 200, error: nil, looksLikeGGUF: looksGGUF)
        guard case .success = outcome else {
            DownloadFileRescuer.cleanup(stashed)
            errors[id] = outcome.userMessage
            return
        }

        do {
            try DownloadFileRescuer.install(stashed: stashed, to: destination)
        } catch {
            errors[id] = "Could not save model: \(error.localizedDescription)"
        }
    }

    private func fail(id: String, error: Error) {
        let outcome = DownloadOutcomeClassifier.classify(
            httpStatus: nil, error: error, looksLikeGGUF: false)
        tasks[id] = nil
        progress[id] = nil
        lastProgressPublish[id] = nil
        if case .cancelled = outcome { return }
        errors[id] = outcome.userMessage
    }

    private func publishProgress(id: String, fraction: Double, force: Bool = false) {
        let clamped = min(1, max(0, fraction))
        let now = Date().timeIntervalSinceReferenceDate
        if !force, let last = lastProgressPublish[id],
           clamped < 1,
           clamped - last.fraction < 0.0025,
           now - last.time < 0.2 {
            return
        }
        progress[id] = clamped
        lastProgressPublish[id] = (clamped, now)
    }
}
