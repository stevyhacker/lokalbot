import Foundation

/// Chooses the prediction debounce from the last generation's latency. Ported in
/// spirit from Cotabby's `DebouncePolicy`: keep the user's configured delay as
/// the floor (snappy on fast machines), but back off when generations run slow
/// so keystrokes don't pile doomed requests onto a model that can't keep up.
enum CotypingDebouncePolicy {
    static let minimumMilliseconds = 20
    /// Largest backoff we'll add regardless of how slow the model is.
    static let maxBackoffMilliseconds = 600

    static func milliseconds(
        lastLatencyMilliseconds: Int?,
        configured: Int,
        consumedDelayMilliseconds: Int = 0
    ) -> Int {
        let floor = max(minimumMilliseconds, configured)
        let total: Int
        if let last = lastLatencyMilliseconds, last > 0 {
            total = max(floor, min(last / 2, maxBackoffMilliseconds))
        } else {
            total = floor
        }
        return max(0, total - max(0, consumedDelayMilliseconds))
    }
}
