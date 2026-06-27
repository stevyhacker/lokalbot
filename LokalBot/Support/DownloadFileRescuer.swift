import Foundation

/// Rescues a `URLSession` temp download out of the one delegate callback where
/// it is valid, then installs it at its final destination once validation has
/// passed.
///
/// Why split into `stash` then `install`:
/// `URLSession`'s contract is that the URL handed to
/// `urlSession(_:downloadTask:didFinishDownloadingTo:)` is reclaimed the instant
/// that callback returns. Any hop afterwards — a `Task {}`, a
/// `DispatchQueue.async`, an `await` to the main actor — races CFNetwork's
/// cleanup and loses the file. `stash` does the only thing that MUST happen
/// synchronously (a `moveItem` to a location we own); `install` can then run
/// later, after the download has been classified, on whatever actor the caller
/// prefers. Both halves are pure `FileManager` logic so they unit-test without
/// any networking stack.
enum DownloadFileRescuer {
    /// Synchronously moves the session temp file to a stable holding URL in the
    /// temporary directory. Returns the holding URL, or `nil` when the move
    /// fails — callers treat `nil` as "could not stage the download" rather
    /// than crashing on a file the OS has already reclaimed.
    ///
    /// MUST be called inside `didFinishDownloadingTo`, before it returns.
    static func stash(_ location: URL, fileManager: FileManager = .default) -> URL? {
        let holding = fileManager.temporaryDirectory
            .appendingPathComponent("LokalBot-download-\(UUID().uuidString)", isDirectory: false)
        do {
            try fileManager.moveItem(at: location, to: holding)
            return holding
        } catch {
            return nil
        }
    }

    /// Atomically replaces `destination` with the stashed file, creating the
    /// parent directory if needed. Uses `replaceItemAt` when a file already
    /// occupies `destination` so a half-written model is never observable;
    /// falls back to a plain move for a first install. Consumes `stashed`
    /// either way.
    static func install(stashed: URL, to destination: URL, fileManager: FileManager = .default) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: stashed)
        } else {
            try fileManager.moveItem(at: stashed, to: destination)
        }
    }

    /// Best-effort removal of a stash that will not be installed (rejected as
    /// non-GGUF, superseded, etc.). Errors are swallowed: by the time cleanup
    /// runs the caller already has the real outcome to report, and a leaked
    /// temp file is reaped by the OS.
    static func cleanup(_ stashed: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: stashed)
    }
}
