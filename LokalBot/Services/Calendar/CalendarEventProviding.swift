import Foundation

/// Calendar permission state, mapped off `EKAuthorizationStatus` so callers
/// (the detector, settings UI, tests) never import `EventKit`.
enum CalendarAuthorizationStatus: Equatable {
    case notDetermined
    case restricted
    case denied
    case writeOnly
    case fullAccess
}

/// Read-only window into the user's calendar, narrowed to "which meeting is
/// happening around now". The seam the matching layer and its tests depend on;
/// production wires up ``EventKitCalendarEventProvider``.
protocol CalendarEventProviding: AnyObject {
    var authorizationStatus: CalendarAuthorizationStatus { get }
    /// Requests full read access; completion delivered on the main thread.
    func requestAccess(_ completion: @escaping (Bool) -> Void)
    /// Recordable meetings overlapping the look-around window, sorted by start.
    /// Empty unless access has been granted.
    func meetingCandidates(now: Date) -> [CalendarMeetingCandidate]
}

extension CalendarEventProviding {
    var hasAccess: Bool { authorizationStatus == .fullAccess }

    /// The active meeting at `now`, or nil when access is missing or nothing is
    /// scheduled. Convenience over `meetingCandidates(now:).activeCandidate(at:)`.
    func activeCandidate(now: Date) -> CalendarMeetingCandidate? {
        guard hasAccess else { return nil }
        return meetingCandidates(now: now).activeCandidate(at: now)
    }
}
