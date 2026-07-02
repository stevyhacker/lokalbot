import Foundation

/// Installs a downloaded temp file at its final destination once validation
/// has passed. Pure `FileManager` logic so it unit-tests without any
/// networking stack.
enum DownloadFileRescuer {
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
