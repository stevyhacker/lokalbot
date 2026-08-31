import CryptoKit
import Foundation

struct ChatLoadResult {
    struct Issue: Equatable {
        let file: String
        let detail: String

        var message: String { "\(file): \(detail)" }
    }

    let conversations: [Conversation]
    let issues: [Issue]
}

private enum ChatStoreError: LocalizedError {
    case unavailable(path: String, detail: String)
    case missingSealedRepresentation

    var errorDescription: String? {
        switch self {
        case .unavailable(let path, let detail):
            return "Chat storage at \(path) is unavailable: \(detail)"
        case .missingSealedRepresentation:
            return "The encrypted conversation could not be encoded."
        }
    }
}

/// Persists chat conversations as one JSON file per conversation under
/// `<root>/chats/`, mirroring the file-per-document layout used for meetings
/// and journals. Personal scale: the whole set loads into memory and each
/// save rewrites a single small file atomically.
@MainActor
final class ChatStore {
    private let directory: URL
    private let fileManager: FileManager
    private let encryptionKey: @MainActor () throws -> SymmetricKey
    private let preparationError: ChatStoreError?

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        encryptionKey: @escaping @MainActor () throws -> SymmetricKey = {
            try KeychainSecrets.symmetricKey(account: "chat-key")
        }
    ) {
        directory = rootURL.appendingPathComponent("chats", isDirectory: true)
        self.fileManager = fileManager
        self.encryptionKey = encryptionKey
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            preparationError = nil
        } catch {
            preparationError = .unavailable(
                path: directory.path,
                detail: error.localizedDescription
            )
        }
    }

    func loadAll() throws -> ChatLoadResult {
        try ensureReady()
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let encryptedFiles = files.filter { $0.pathExtension == "enc" }
        let key = encryptedFiles.isEmpty ? nil : try encryptionKey()
        var conversations: [Conversation] = []
        var issues: [ChatLoadResult.Issue] = []

        for file in files {
            switch file.pathExtension {
            case "enc":
                do {
                    guard let key else { throw ChatStoreError.missingSealedRepresentation }
                    conversations.append(try loadEncrypted(file, using: key))
                } catch {
                    issues.append(issue(for: file, error: error))
                }
            case "json":
                loadLegacy(file, conversations: &conversations, issues: &issues)
            default:
                continue
            }
        }

        return ChatLoadResult(
            conversations: conversations.sorted { $0.updatedAt > $1.updatedAt },
            issues: issues
        )
    }

    /// Encode → AES-GCM seal (per-install Keychain key) → atomic write. Throws
    /// unless the sealed file lands durably.
    func save(_ conversation: Conversation) throws {
        try ensureReady()
        let key = try encryptionKey()
        let data = try Self.encoder.encode(conversation)
        guard let combined = try AES.GCM.seal(data, using: key).combined else {
            throw ChatStoreError.missingSealedRepresentation
        }
        try combined.write(to: encryptedFileURL(for: conversation.id), options: .atomic)
    }

    func delete(_ id: UUID) throws {
        try ensureReady()
        try FileSystemSupport.removeIfPresent(
            encryptedFileURL(for: id),
            fileManager: fileManager
        )
        try FileSystemSupport.removeIfPresent(
            legacyFileURL(for: id),
            fileManager: fileManager
        )
    }

    private static let encoder = JSONCoding.prettyPrintedISO8601Encoder()
    private static let decoder = JSONCoding.iso8601Decoder()

    private func ensureReady() throws {
        if let preparationError { throw preparationError }
    }

    private func encryptedFileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json.enc")
    }

    private func legacyFileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func loadEncrypted(_ file: URL, using key: SymmetricKey) throws -> Conversation {
        let data = try Data(contentsOf: file)
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: key)
        return try Self.decoder.decode(Conversation.self, from: plaintext)
    }

    /// Load legacy plaintext before attempting its best-effort migration. The
    /// conversation remains available even when sealing or cleanup fails.
    private func loadLegacy(
        _ file: URL,
        conversations: inout [Conversation],
        issues: inout [ChatLoadResult.Issue]
    ) {
        do {
            let data = try Data(contentsOf: file)
            let conversation = try Self.decoder.decode(Conversation.self, from: data)
            conversations.append(conversation)
            do {
                try save(conversation)
                try fileManager.removeItem(at: file)
            } catch {
                issues.append(.init(
                    file: file.lastPathComponent,
                    detail: "loaded, but plaintext migration failed: \(error.localizedDescription)"
                ))
            }
        } catch {
            issues.append(issue(for: file, error: error))
        }
    }

    private func issue(for file: URL, error: Error) -> ChatLoadResult.Issue {
        .init(file: file.lastPathComponent, detail: error.localizedDescription)
    }
}
