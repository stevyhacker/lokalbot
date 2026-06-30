import Combine
import Foundation

/// Polls the Accessibility-focused field on a timer and publishes a value-type
/// snapshot. Trimmed port of Cotabby's `FocusTracker`/`FocusTrackingModel`: no
/// AXObserver (inconsistent across hosts), just a main-runloop timer plus an
/// out-of-band `refreshNow()` the coordinator calls after a keystroke settles.
/// The timer uses Cotabby's idle backoff: fast after activity, slower after
/// repeated no-change captures.
@MainActor
final class CotypingFocusTracker: ObservableObject {
    @Published private(set) var focus: CotypingFocus = .none

    /// Fired (in addition to the publisher) whenever the focus changes.
    var onChange: ((CotypingFocus) -> Void)?

    private var timer: Timer?
    private var baseIntervalMs: Int
    private var scheduledIntervalMs: Int?
    private var pollBackoff = CotypingFocusPollBackoff()
    private var capabilityFlickerGate = CotypingFocusCapabilityFlickerGate()

    init(intervalMs: Int = 80) {
        self.baseIntervalMs = intervalMs
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        pollBackoff.reset()
        refreshNow()
        scheduleTimer()
    }

    private var effectiveIntervalMs: Int {
        max(1, baseIntervalMs) * pollBackoff.captureStride
    }

    private func scheduleTimer() {
        timer?.invalidate()
        scheduledIntervalMs = effectiveIntervalMs
        let timer = Timer(timeInterval: Double(effectiveIntervalMs) / 1000.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTimerTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func rescheduleTimerIfNeeded() {
        guard timer != nil, scheduledIntervalMs != effectiveIntervalMs else { return }
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        scheduledIntervalMs = nil
        pollBackoff.reset()
        capabilityFlickerGate = CotypingFocusCapabilityFlickerGate()
        if focus != .none {
            focus = .none
            onChange?(.none)
        }
    }

    private func handleTimerTick() {
        let previous = focus
        let latest = captureFocus(includeSurface: false, includeURL: false, includeStyle: false)
        pollBackoff.recordCapture(didChange: latest != previous)
        rescheduleTimerIfNeeded()
    }

    /// Synchronous capture. Publishes only on a real change so SwiftUI surfaces
    /// and the coordinator do not churn every tick.
    @discardableResult
    func refreshNow(includeSurface: Bool = false, includeURL: Bool = false, includeStyle: Bool = false) -> CotypingFocus {
        pollBackoff.reset()
        let latest = captureFocus(includeSurface: includeSurface, includeURL: includeURL, includeStyle: includeStyle)
        rescheduleTimerIfNeeded()
        return latest
    }

    private func captureFocus(includeSurface: Bool, includeURL: Bool, includeStyle: Bool) -> CotypingFocus {
        let latestRaw = CotypingAXHelper.resolveFocus(
            includeSurface: includeSurface, includeURL: includeURL, includeStyle: includeStyle)
        let latest: CotypingFocus
        switch capabilityFlickerGate.evaluate(latestRaw) {
        case .apply:
            latest = latestRaw
        case .suppress:
            latest = focus
        }
        if latest != focus {
            focus = latest
            onChange?(latest)
        }
        return latest
    }
}
