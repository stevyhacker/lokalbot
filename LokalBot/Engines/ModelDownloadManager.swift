import Foundation

/// Built-in LLM backend, part 2 of 3: model download orchestration. Validated,
/// staged downloads of catalog (and, via `download(url:fileName:id:)`, arbitrary
/// Hugging Face) GGUF models into <storage>/models/.
@MainActor
final class ModelDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {

    static let shared = ModelDownloadManager()

    @Published private(set) var progress: [String: Double] = [:]   // entry id → 0…1
    @Published private(set) var errors: [String: String] = [:]

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var rangedTasks: [String: Task<Void, Never>] = [:]
    private var destinations: [Int: (id: String, url: URL)] = [:]
    private var lastProgressPublish: [String: (fraction: Double, time: TimeInterval)] = [:]

    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "LokalBot.ModelDownloadManager.URLSessionDelegate"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private lazy var session = URLSession(
        configuration: Self.downloadConfiguration(),
        delegate: self,
        delegateQueue: delegateQueue)

    private lazy var rangedSession = URLSession(configuration: Self.downloadConfiguration())

    func download(_ entry: ModelCatalog.Entry, storage: StorageManager) {
        download(url: entry.url, fileName: entry.fileName, id: entry.id, storage: storage)
    }

    /// Generic GGUF download keyed by an arbitrary id (catalog id, or a Hugging
    /// Face "<repo>/<file>" key for browsed models). Idempotent per id.
    func download(url urlString: String, fileName: String, id: String, storage: StorageManager) {
        guard tasks[id] == nil, rangedTasks[id] == nil, let url = URL(string: urlString) else { return }
        let folder = storage.rootURL.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(fileName)
        progress[id] = 0
        errors[id] = nil
        startAcceleratedDownload(url: url, destination: destination, id: id)
    }

    func cancel(_ entry: ModelCatalog.Entry) { cancel(id: entry.id) }

    func cancel(id: String) {
        tasks[id]?.cancel()
        rangedTasks[id]?.cancel()
        tasks[id] = nil
        rangedTasks[id] = nil
        progress[id] = nil
        lastProgressPublish[id] = nil
    }

    func delete(_ entry: ModelCatalog.Entry, storage: StorageManager) {
        guard !entry.isBundled else { return }
        try? FileManager.default.removeItem(
            at: storage.rootURL.appendingPathComponent("models/\(entry.fileName)"))
        objectWillChange.send()
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        let taskID = downloadTask.taskIdentifier
        Task { @MainActor in
            if let (id, _) = destinations[taskID] {
                publishProgress(id: id, fraction: fraction)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // Stage synchronously — `location` is deleted when this delegate returns.
        let taskID = downloadTask.taskIdentifier
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
        let stash = DownloadFileRescuer.stash(location)
        Task { @MainActor in
            defer { tasks = tasks.filter { $0.value.taskIdentifier != taskID } }
            guard let (id, destination) = destinations[taskID] else { return }
            destinations[taskID] = nil
            progress[id] = nil
            lastProgressPublish[id] = nil
            let looksGGUF = stash.map { ModelFileValidator.looksLikeGGUF($0) } ?? false
            let outcome = DownloadOutcomeClassifier.classify(
                httpStatus: status, error: nil, looksLikeGGUF: looksGGUF)
            guard case .success = outcome, let stash else {
                stash.map { try? FileManager.default.removeItem(at: $0) }
                errors[id] = outcome.userMessage
                return
            }
            do {
                try DownloadFileRescuer.install(stashed: stash, to: destination)
            } catch {
                errors[id] = "Could not save model: \(error.localizedDescription)"
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        let taskID = task.taskIdentifier
        Task { @MainActor in
            let outcome = DownloadOutcomeClassifier.classify(
                httpStatus: nil, error: error, looksLikeGGUF: false)
            fail(taskID: taskID, message: outcome.userMessage)
        }
    }

    private func fail(taskID: Int, message: String) {
        if let (id, _) = destinations[taskID] {
            errors[id] = message
            progress[id] = nil
            destinations[taskID] = nil
            tasks[id] = nil
            lastProgressPublish[id] = nil
        }
    }

    private nonisolated static func downloadConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = ParallelRangeDownloader.defaultMaxConcurrentParts
        configuration.networkServiceType = .responsiveData
        configuration.httpShouldSetCookies = false
        return configuration
    }

    private func startAcceleratedDownload(url: URL, destination: URL, id: String) {
        let session = rangedSession
        let task = Task(priority: .utility) { [weak self] in
            do {
                let stashed = try await ParallelRangeDownloader.download(from: url, session: session) { update in
                    Task { @MainActor [weak self] in
                        self?.publishProgress(id: id, fraction: update.fractionCompleted)
                    }
                }
                await self?.finishAcceleratedDownload(id: id, destination: destination, stashed: stashed)
            } catch is ParallelRangeDownloader.FallbackRequired {
                await self?.fallBackToURLSessionDownload(url: url, destination: destination, id: id)
            } catch {
                await self?.failAcceleratedDownload(id: id, error: error)
            }
        }
        rangedTasks[id] = task
    }

    private func fallBackToURLSessionDownload(url: URL, destination: URL, id: String) {
        guard rangedTasks[id] != nil else { return }
        rangedTasks[id] = nil
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        let task = session.downloadTask(with: request)
        destinations[task.taskIdentifier] = (id, destination)
        tasks[id] = task
        publishProgress(id: id, fraction: 0, force: true)
        task.resume()
    }

    private func finishAcceleratedDownload(id: String, destination: URL, stashed: URL) {
        defer {
            rangedTasks[id] = nil
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

    private func failAcceleratedDownload(id: String, error: Error) {
        let outcome = DownloadOutcomeClassifier.classify(
            httpStatus: nil, error: error, looksLikeGGUF: false)
        rangedTasks[id] = nil
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
