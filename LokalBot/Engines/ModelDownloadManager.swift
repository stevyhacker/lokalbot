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
    private var destinations: [Int: (id: String, url: URL)] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self,
                                          delegateQueue: .main)

    func download(_ entry: ModelCatalog.Entry, storage: StorageManager) {
        download(url: entry.url, fileName: entry.fileName, id: entry.id, storage: storage)
    }

    /// Generic GGUF download keyed by an arbitrary id (catalog id, or a Hugging
    /// Face "<repo>/<file>" key for browsed models). Idempotent per id.
    func download(url urlString: String, fileName: String, id: String, storage: StorageManager) {
        guard tasks[id] == nil, let url = URL(string: urlString) else { return }
        let folder = storage.rootURL.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let task = session.downloadTask(with: url)
        destinations[task.taskIdentifier] = (id, folder.appendingPathComponent(fileName))
        tasks[id] = task
        progress[id] = 0
        errors[id] = nil
        task.resume()
    }

    func cancel(_ entry: ModelCatalog.Entry) { cancel(id: entry.id) }

    func cancel(id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        progress[id] = nil
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
            if let (id, _) = destinations[taskID] { progress[id] = fraction }
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
        }
    }
}
