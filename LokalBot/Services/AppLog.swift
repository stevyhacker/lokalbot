import Foundation
import Logging

/// LokalBot's logging front door. Wraps swift-log so the whole app logs through
/// one bootstrap that fans every event out to both stdout (visible in Console
/// and when launched from a terminal) and the on-disk `debug.log` the app has
/// always written. The legacy `lokalbotv3Log(_:)` shim is rerouted to ``line(_:)``
/// so existing call sites keep working unchanged.
///
/// Deliberately NOT main-actor isolated: `lokalbotv3Log` is a free function
/// called from any thread/actor, swift-log's `Logger` is a thread-safe value
/// type, and the only shared mutable state (the bootstrap latch) is lock-guarded.
enum AppLog {
    private static let bootstrapLock = NSLock()
    private nonisolated(unsafe) static var didBootstrap = false

    /// Installs the swift-log backend exactly once per process. Safe to call
    /// from anywhere, any number of times: the second and later calls are
    /// no-ops. The latch is mandatory, not just an optimization —
    /// `LoggingSystem.bootstrap` traps on a second invocation.
    static func bootstrap() {
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }
        guard !didBootstrap else { return }
        didBootstrap = true

        // One shared sink for the whole process, captured by the factory so
        // every category's handler writes to the same file/handle.
        let sink = FileLogSink(fileURL: debugLogURL())
        LoggingSystem.bootstrap { label in
            MultiplexLogHandler([
                StreamLogHandler.standardOutput(label: label),
                FileLogHandler(label: label, sink: sink),
            ])
        }
    }

    /// A logger for a named subsystem, e.g. `AppLog.category("download")`.
    /// Labels are namespaced under the bundle id so file lines and Console
    /// share one consistent category vocabulary.
    static func category(_ name: String) -> Logging.Logger {
        Logging.Logger(label: "\(AppIdentifiers.bundleID).\(name)")
    }

    /// Logs `message` at `.info` on the default category. This is the single
    /// entry point the rerouted `lokalbotv3Log(_:)` calls, preserving the old
    /// "one plain line of diagnostics" behavior on top of swift-log.
    ///
    /// `bootstrap()` is expected to have run at launch before the first call;
    /// a line emitted earlier still logs, just via swift-log's default stdout
    /// backend rather than the file.
    static func line(_ message: String) {
        category("app").info("\(message)")
    }

    /// `<App Support>/me.dotenv.LokalBot/debug.log` — the same file the app has
    /// always appended diagnostics to, so existing tooling keeps working. The
    /// temp-directory fallback avoids a force-unwrap on the (in practice always
    /// present) Application Support URL.
    private static func debugLogURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(AppIdentifiers.bundleID, isDirectory: true)
            .appendingPathComponent("debug.log", isDirectory: false)
    }
}
