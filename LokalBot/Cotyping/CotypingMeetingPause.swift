import Foundation

/// Policy for pausing cotyping while a meeting records, kept pure for unit
/// tests. Two things happen during a recording: the machine is busy with
/// capture + transcription prewarm, and ghost text popping up mid-call (often
/// while screen-sharing) is exactly when suggestions are least welcome. The
/// coordinator checks the live flag before every generation; this type owns
/// the state transition when the flag flips.
enum CotypingMeetingPause {

    static let reason = "Paused while a meeting is recording."

    /// The state to move to when the recording flag flips, or nil to leave
    /// the current state alone. Pausing always wins; resuming only clears the
    /// pause label itself (never a disabled reason someone else set).
    static func transition(recordingActive: Bool, current: CotypingState) -> CotypingState? {
        if recordingActive {
            return current == .disabled(reason) ? nil : .disabled(reason)
        }
        return current == .disabled(reason) ? .idle : nil
    }
}
