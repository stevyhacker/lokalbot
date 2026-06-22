import Foundation
import UserNotifications

/// Local notifications that announce recording start/stop, so the user knows a
/// meeting is being captured without keeping the window open. This is the
/// "push" half of the menu-bar-only experience; the always-visible menu bar
/// timer is the "pull" half.
///
/// Authorization is requested lazily the first time a recording actually
/// starts — a new user is never hit with a notification prompt before they've
/// done anything, and if they decline, the menu bar timer still covers the
/// "is it recording?" question.
@MainActor
final class RecordingNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RecordingNotifier()

    private var didRequestAuthorization = false

    /// Install the foreground-presentation delegate. Called once at launch from
    /// the interactive (non-headless, non-UI-test) path.
    func bootstrap() {
        UNUserNotificationCenter.current().delegate = self
    }

    private func ensureAuthorization() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func recordingStarted(title: String) {
        ensureAuthorization()
        post(title: "Recording started", body: title)
    }

    func recordingStopped(title: String, duration: TimeInterval, willTranscribe: Bool) {
        let minutes = max(1, Int(duration / 60))
        var body = "\(title) · \(minutes) min"
        if willTranscribe { body += " · transcribing…" }
        post(title: "Recording saved", body: body)
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // `trigger: nil` delivers immediately. A fresh identifier each time so a
        // start and a stop don't coalesce into one another.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show the banner even when LokalBotV2 happens to be the active app (e.g. the
    // window is open), instead of silently dropping it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
