import Foundation

/// Cross-process marker-file truth for external-agent access and LLM wakeup.
struct AgentAccessGate {
    var root: URL

    init(root: URL = SessionLookup.storageRootURL) {
        self.root = root
    }

    var controlDirectory: URL {
        root.appendingPathComponent("control", isDirectory: true)
    }

    var accessMarkerURL: URL {
        controlDirectory.appendingPathComponent("agent-access-enabled")
    }

    var wakeFileURL: URL {
        controlDirectory.appendingPathComponent("agent-wake")
    }

    var wakeErrorURL: URL {
        controlDirectory.appendingPathComponent("agent-wake-error")
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: accessMarkerURL.path)
    }

    func enable() throws {
        try FileManager.default.createDirectory(
            at: controlDirectory,
            withIntermediateDirectories: true)
        try Data().write(to: accessMarkerURL)
    }

    func disable() {
        try? FileManager.default.removeItem(at: accessMarkerURL)
    }

    func touchWake() throws {
        try FileManager.default.createDirectory(
            at: controlDirectory,
            withIntermediateDirectories: true)
        try Data().write(to: wakeFileURL)
    }

    func consumeWake() -> Bool {
        guard FileManager.default.fileExists(atPath: wakeFileURL.path) else { return false }
        try? FileManager.default.removeItem(at: wakeFileURL)
        return true
    }

    var pendingWake: Bool {
        FileManager.default.fileExists(atPath: wakeFileURL.path)
    }

    func writeWakeError(_ message: String) {
        try? FileManager.default.createDirectory(
            at: controlDirectory,
            withIntermediateDirectories: true)
        try? Data(message.utf8).write(to: wakeErrorURL)
    }

    func clearWakeError() {
        try? FileManager.default.removeItem(at: wakeErrorURL)
    }

    func readWakeError() -> String? {
        guard let data = try? Data(contentsOf: wakeErrorURL) else { return nil }
        let message = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }
}
