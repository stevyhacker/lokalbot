import Combine
import Foundation
import IOKit.ps

/// Publishes whether the Mac is on battery and whether Low Power Mode is enabled,
/// so power-aware features (e.g. deferring heavy local generation) can react.
///
/// On the main actor because `@Published` feeds SwiftUI. Battery state is sampled
/// on a ~30s timer — charger plug/unplug isn't latency-sensitive for our use, and
/// a slow poll keeps wakeups negligible. Low Power Mode toggles arrive immediately
/// via `NSProcessInfoPowerStateDidChange`, which also triggers a full refresh so
/// both flags stay coherent.
@MainActor
final class PowerSourceMonitor: ObservableObject {
    @Published private(set) var isOnBattery = false
    @Published private(set) var isLowPower = false

    private static let pollInterval: TimeInterval = 30

    private var pollTimer: Timer?
    private var powerStateObserver: NSObjectProtocol?

    /// Seed the published flags at construction so a view bound before `start()`
    /// shows the real state instead of the `false` defaults.
    init() {
        refresh()
    }

    deinit {
        pollTimer?.invalidate()
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
        }
    }

    func start() {
        stop()
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
            self.powerStateObserver = nil
        }
    }

    private func refresh() {
        isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        isOnBattery = Self.readIsOnBattery()
    }

    /// True when the providing power source is the internal battery. Defaults to
    /// false (treat as AC) when IOKit can't name a providing source — desktop Macs
    /// have no battery and report none, and "not on battery" is the safe read there.
    private static func readIsOnBattery() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let providing = IOPSGetProvidingPowerSourceType(snapshot) else {
            return false
        }
        let source = providing.takeUnretainedValue() as String
        return source != kIOPSACPowerValue
    }
}
