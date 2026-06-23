import Foundation

/// Chooses the prediction debounce from the last generation's latency. Ported in
/// spirit from Cotabby's `DebouncePolicy`: keep the user's configured delay as
/// the floor (snappy on fast machines), but back off when generations run slow
/// so keystrokes don't pile doomed requests onto a model that can't keep up.
enum CotypingDebouncePolicy {
    /// Largest backoff we'll add regardless of how slow the model is.
    static let maxBackoffMilliseconds = 600

    static func milliseconds(lastLatencyMilliseconds: Int?, configured: Int) -> Int {
        guard let last = lastLatencyMilliseconds, last > 0 else { return configured }
        return max(configured, min(last / 2, maxBackoffMilliseconds))
    }
}
