import Combine
import Foundation

/// Polls the Accessibility-focused field on a timer and publishes a value-type
/// snapshot. Trimmed port of Cotabby's `FocusTracker`/`FocusTrackingModel`: no
/// AXObserver (inconsistent across hosts), just a main-runloop timer plus an
/// out-of-band `refreshNow()` the coordinator calls after a keystroke settles.
@MainActor
final class CotypingFocusTracker: ObservableObject {
    @Published private(set) var focus: CotypingFocus = .none

    /// Fired (in addition to the publisher) whenever the focus changes.
    var onChange: ((CotypingFocus) -> Void)?

    private var timer: Timer?
    private var intervalMs: Int

    init(intervalMs: Int = 200) {
        self.intervalMs = intervalMs
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        refreshNow()
        let timer = Timer(timeInterval: Double(intervalMs) / 1000.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refreshNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if focus != .none {
            focus = .none
            onChange?(.none)
        }
    }

    /// Synchronous capture. Publishes only on a real change so SwiftUI surfaces
    /// and the coordinator do not churn every tick.
    @discardableResult
    func refreshNow(includeSurface: Bool = false, includeURL: Bool = false) -> CotypingFocus {
        let latest = CotypingAXHelper.resolveFocus(includeSurface: includeSurface, includeURL: includeURL)
        if latest != focus {
            focus = latest
            onChange?(latest)
        }
        return latest
    }
}
