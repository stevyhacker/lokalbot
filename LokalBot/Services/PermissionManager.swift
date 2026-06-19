import AVFoundation
import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// The exactly three macOS privacy permissions LokalBotV1 needs. System-audio
/// capture rides on the `com.apple.security.device.audio-input` entitlement, so
/// it is not a TCC prompt and is intentionally absent here.
///
/// Pure metadata plus stateless TCC reads: the enum stays off `@MainActor` so
/// its logic (titles, grant checks) is unit-testable on any thread, while the
/// observable cache lives on `PermissionManager`.
enum AppPermission: CaseIterable, Identifiable, Hashable {
    case microphone
    case screenRecording
    case accessibility

    var id: Self { self }

    /// System-Settings-style label.
    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        }
    }

    /// One-sentence rationale shown beside each permission row.
    var why: String {
        switch self {
        case .microphone:
            "Records your side of the meeting from the microphone."
        case .screenRecording:
            "Captures periodic screenshots that are OCR'd into your meeting timeline."
        case .accessibility:
            "Reads window titles to track your activity."
        }
    }

    /// Real TCC state, queried without ever prompting the user.
    ///
    /// Screen Recording uses the *preflight* probe rather than
    /// `CGRequestScreenCaptureAccess` precisely so that reading status can never
    /// surface the system dialog as a side effect.
    var isGranted: Bool {
        switch self {
        case .microphone:
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .screenRecording:
            CGPreflightScreenCaptureAccess()
        case .accessibility:
            AXIsProcessTrusted()
        }
    }

    /// Fires the native permission prompt. This is a no-op once the system has
    /// already decided (a denied permission can only be changed in System
    /// Settings), so callers pair it with `PermissionManager.openSettings(for:)`.
    func request() {
        switch self {
        case .microphone:
            // Empty completion on purpose: the grant arrives asynchronously and
            // is surfaced through `PermissionManager.granted`, not this callback.
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            // `prompt: true` shows the "Open System Settings" dialog on first ask.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    /// Deep link to this permission's System Settings pane. Optional because
    /// `URL(string:)` is failable; callers skip opening when it is `nil`.
    var settingsURL: URL? {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .accessibility: pane = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}

/// Single source of truth for LokalBotV1's permission state.
///
/// Folds the three ad-hoc TCC checks once scattered across views and services
/// into one observable cache so every surface reads the same value. A short poll
/// is the only way to notice a grant the user just made over in System Settings
/// (TCC posts no change notification), so the manager exposes explicit
/// `startPolling()`/`stopPolling()` driven by the permissions UI's lifecycle —
/// an established user pays zero idle main-thread wakeups once that UI is closed.
@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    /// Cached grant state, refreshed by `refresh()` and the poll. Published so
    /// SwiftUI surfaces redraw the moment a permission flips.
    @Published private(set) var granted: [AppPermission: Bool] = [:]

    private var pollTimer: Timer?

    private init() {
        refresh()
    }

    /// Re-reads every permission and republishes only on a real change. TCC
    /// reads are cheap, but `@Published` fires on assignment even when the value
    /// is identical, so the diff avoids redrawing surfaces on every poll tick.
    func refresh() {
        var latest: [AppPermission: Bool] = [:]
        latest.reserveCapacity(AppPermission.allCases.count)
        for permission in AppPermission.allCases {
            latest[permission] = permission.isGranted
        }
        if latest != granted {
            granted = latest
        }
    }

    /// Triggers the native prompt for `permission`, then refreshes so any
    /// synchronous grant (Accessibility, Screen Recording) is reflected at once.
    /// The asynchronous microphone grant is picked up by the next poll tick.
    func request(_ permission: AppPermission) {
        permission.request()
        refresh()
    }

    /// Opens System Settings straight to `permission`'s pane.
    func openSettings(for permission: AppPermission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Whether all three permissions are currently granted.
    var allGranted: Bool {
        AppPermission.allCases.allSatisfy { granted[$0] == true }
    }

    /// Arms a ~1.5s catch-up poll so the UI reflects grants made over in System
    /// Settings. Idempotent: a second call while already polling is a no-op.
    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Tears down the poll. Callers invoke this when the permissions UI
    /// disappears so no idle timer survives the flow that needed it.
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Re-launches LokalBotV1. Accessibility grants only take effect at process
    /// launch, so granting it mid-session needs a restart to apply. Spawns a
    /// fresh instance via `open -n`, then terminates this one a beat later.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        task.environment = ProcessInfo.processInfo.environment
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
}
