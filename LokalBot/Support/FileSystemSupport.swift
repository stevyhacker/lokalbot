import Foundation

/// Shared filesystem policy for optional app artifacts.
///
/// A missing file is an expected state for artifacts that have not been
/// created yet. Permission, I/O, and filesystem-corruption errors are not;
/// callers must continue to surface those instead of collapsing every failure
/// into "not found."
enum FileSystemSupport {
    static func isMissing(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        guard cocoaError.domain == NSCocoaErrorDomain else { return false }
        return cocoaError.code == CocoaError.Code.fileNoSuchFile.rawValue
            || cocoaError.code == CocoaError.Code.fileReadNoSuchFile.rawValue
    }

    static func attributesIfPresent(
        at url: URL,
        fileManager: FileManager = .default
    // FileManager exposes attributes through this heterogeneous dictionary.
    ) throws -> [FileAttributeKey: Any]? { // swiftlint:disable:this no_dynamic_any
        do {
            return try fileManager.attributesOfItem(atPath: url.path)
        } catch where isMissing(error) {
            return nil
        }
    }

    static func itemExists(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        try attributesIfPresent(at: url, fileManager: fileManager) != nil
    }

    static func itemIsDirectory(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> Bool? {
        guard let attributes = try attributesIfPresent(at: url, fileManager: fileManager) else {
            return nil
        }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    static func removeIfPresent(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch where isMissing(error) {
            return
        }
    }
}
