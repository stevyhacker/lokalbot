import Combine
import Foundation

enum ScreenMemoryAccessError: LocalizedError {
    case disabled

    var errorDescription: String? {
        switch self {
        case .disabled:
            FileLibraryToolProvider.screenAccessDisabledMessage
        }
    }
}

/// Cross-process marker-file truth for the more-sensitive screen-memory scope.
///
/// This deliberately does not reuse `AgentAccessGate`. Enabling meeting-library
/// access, or issuing an Agent Mode meeting capability, must never grant access
/// to window titles, OCR text, activity blocks, or screenshot metadata.
struct ScreenMemoryAccessGate {
    static let markerName = "screen-memory-access-enabled"

    var root: URL

    init(root: URL = SessionLookup.storageRootURL) {
        self.root = root
    }

    var controlDirectory: URL {
        root.appendingPathComponent("control", isDirectory: true)
    }

    var accessMarkerURL: URL {
        controlDirectory.appendingPathComponent(Self.markerName)
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: accessMarkerURL.path)
    }

    /// Kept as a method to parallel `AgentAccessGate` at call sites while
    /// intentionally accepting no environment-borne meeting capability.
    func isAuthorized() -> Bool {
        isEnabled
    }

    func requireAuthorized() throws {
        guard isAuthorized() else { throw ScreenMemoryAccessError.disabled }
    }

    func enable() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: controlDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // `createDirectory(attributes:)` does not re-apply attributes when the
        // shared control directory already exists (for example after enabling
        // meeting access first), so harden the existing directory explicitly.
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: controlDirectory.path)
        try Data().write(to: accessMarkerURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: accessMarkerURL.path)
    }

    func disable() {
        try? FileManager.default.removeItem(at: accessMarkerURL)
    }
}

/// Small app-side owner for the independent screen-memory marker.
///
/// Unlike `AgentAccessManager`, this has no wake watcher or inference lease:
/// every screen-memory MCP tool is a read-only SQLite query that works while
/// the app is closed.
@MainActor
final class ScreenMemoryAccessManager: ObservableObject {
    @Published private(set) var isEnabled = false

    private let gate: ScreenMemoryAccessGate

    init(gate: ScreenMemoryAccessGate = ScreenMemoryAccessGate()) {
        self.gate = gate
    }

    func start() {
        isEnabled = gate.isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try gate.enable()
            } catch {
                return
            }
            isEnabled = true
        } else {
            gate.disable()
            isEnabled = false
        }
    }
}
