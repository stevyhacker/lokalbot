import Foundation

/// Persisted preferences for update checks. Mirrors AppSettings' pattern but
/// kept separate so the main settings codable schema stays stable.
///
/// Automatic checks are **opt-in and default-off**. LokalBot is local-first —
/// audio never leaves your Mac — and an update check is an outbound request
/// to GitHub, so it never happens at launch unless the user enables it here.
/// Manual checks (the Settings button) are a separate, explicitly-clicked path.
@MainActor
final class UpdateSettings: ObservableObject {
    static let shared = UpdateSettings()

    /// Minimum time between automatic checks — once a day. `nonisolated` so
    /// the pure `isDue(...)` helper can use it as a default off the main actor.
    nonisolated static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private let automaticallyCheckKey = "lokalbot.update.autoCheck"
    private let lastCheckKey = "lokalbot.update.lastCheckTimestamp"

    @Published var automaticallyCheckForUpdates: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyCheckForUpdates, forKey: automaticallyCheckKey)
        }
    }

    private init() {
        // Absent key → `bool(forKey:)` returns false, which is the intended default.
        self.automaticallyCheckForUpdates = UserDefaults.standard.bool(forKey: automaticallyCheckKey)
    }

    var lastCheckDate: Date? {
        let timestamp = UserDefaults.standard.double(forKey: lastCheckKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    func markCheckedNow(date: Date = Date()) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastCheckKey)
    }

    /// True when the opt-in is on *and* enough time has elapsed since the last check.
    func isDueForAutomaticCheck(now: Date = Date()) -> Bool {
        guard automaticallyCheckForUpdates else { return false }
        return Self.isDue(lastCheck: lastCheckDate, now: now,
                          interval: Self.automaticCheckInterval)
    }

    /// Pure timing helper (no UserDefaults), kept `nonisolated` so it can
    /// be unit-tested synchronously off the main actor.
    nonisolated static func isDue(lastCheck: Date?, now: Date,
                                  interval: TimeInterval = automaticCheckInterval) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}
