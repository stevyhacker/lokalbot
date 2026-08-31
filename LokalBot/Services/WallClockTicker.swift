import Foundation

/// A run-loop-backed wall-clock ticker shared by background schedulers.
/// Re-evaluating the current date on each tick keeps scheduling correct across
/// sleep, wake, and daylight-saving changes.
@MainActor
final class WallClockTicker {
    private var timer: Timer?

    init(interval: TimeInterval = 60, action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }
}
