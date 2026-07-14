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

    private static let detectionCategory = "lokalbot.meeting-detected"
    private static let recordAction = "lokalbot.record-detected-meeting"
    private static let ignoreAction = "lokalbot.ignore-detected-meeting"

    private struct PendingDetection {
        let expiresAt: Date
        let record: @MainActor () -> Void
    }

    private var pendingDetections: [String: PendingDetection] = [:]

    /// Install the foreground-presentation delegate. Called once at launch from
    /// the interactive (non-headless, non-UI-test) path.
    func bootstrap() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(
            identifier: Self.recordAction,
            title: "Record",
            options: [.foreground])
        let ignore = UNNotificationAction(
            identifier: Self.ignoreAction,
            title: "Ignore")
        let category = UNNotificationCategory(
            identifier: Self.detectionCategory,
            actions: [record, ignore],
            intentIdentifiers: [],
            options: [.customDismissAction])
        center.setNotificationCategories([category])
    }

    func recordingStarted(title: String) {
        post(title: "Recording started", body: title)
    }

    func recordingStopped(title: String, duration: TimeInterval, willTranscribe: Bool) {
        let minutes = max(1, Int(duration / 60))
        var body = "\(title) · \(minutes) min"
        if willTranscribe { body += " · transcribing…" }
        post(title: "Recording saved", body: body)
    }

    /// Posts a real, actionable prompt for `.ask` recording mode. The action
    /// expires so clicking an old notification cannot begin capturing an
    /// unrelated meeting hours later.
    func meetingDetected(title: String,
                         expiresAfter: TimeInterval = 2 * 60,
                         onRecord: @escaping @MainActor () -> Void) {
        purgeExpiredDetections()
        let identifier = "meeting-detected-\(UUID().uuidString)"
        pendingDetections[identifier] = PendingDetection(
            expiresAt: Date().addingTimeInterval(expiresAfter),
            record: onRecord)
        post(
            title: "Meeting detected",
            body: "Record \(title)?",
            identifier: identifier,
            categoryIdentifier: Self.detectionCategory)
    }

    private func post(title: String,
                      body: String,
                      identifier: String = UUID().uuidString,
                      categoryIdentifier: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        // `trigger: nil` delivers immediately. A fresh identifier each time so a
        // start and a stop don't coalesce into one another.
        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        Task {
            let settings = await center.notificationSettings()
            var authorized = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            if settings.authorizationStatus == .notDetermined {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            }
            guard authorized else {
                pendingDetections.removeValue(forKey: identifier)
                return
            }
            try? await center.add(request)
        }
    }

    private func purgeExpiredDetections(now: Date = Date()) {
        pendingDetections = pendingDetections.filter { $0.value.expiresAt > now }
    }

    // Show the banner even when LokalBot happens to be the active app (e.g. the
    // window is open), instead of silently dropping it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await handle(response)
    }

    private func handle(_ response: UNNotificationResponse) {
        let identifier = response.notification.request.identifier
        guard let pending = pendingDetections.removeValue(forKey: identifier) else { return }
        guard response.actionIdentifier == Self.recordAction,
              pending.expiresAt > Date() else { return }
        pending.record()
    }
}
