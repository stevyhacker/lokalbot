import Foundation

/// A calendar event that could line up with a recording: already filtered down
/// to a real, recordable meeting (see ``CalendarEventFilter``) and stripped of
/// EventKit so the matching layer and its tests never import `EventKit`.
struct CalendarMeetingCandidate: Equatable {
    /// Source provider tag, e.g. "eventkit". Persisted on the `Meeting`.
    let provider: String
    /// Stable per-occurrence identifier (event id + occurrence start) so the
    /// repeat-suppression cooldown is keyed on this exact meeting instance.
    let externalID: String
    let title: String
    let startDate: Date
    let endDate: Date
    /// Conferencing link found on the event (Meet/Zoom/Teams/…), if any. The
    /// signal that lets a browser's audio count as a meeting without a window
    /// title match.
    let meetingURL: URL?
    let sourceCalendarTitle: String?

    /// Is this event happening at `now`? In progress, or within `earlyJoin`
    /// before its start (people join a beat early). Calendar end never *stops*
    /// a recording — only audio does — so this is deliberately start-biased.
    func isActive(at now: Date, earlyJoin: TimeInterval = 5 * 60) -> Bool {
        now >= startDate.addingTimeInterval(-earlyJoin) && now <= endDate
    }
}

extension Array where Element == CalendarMeetingCandidate {
    /// The single event that best represents "what is happening now": an
    /// in-progress event (most recently started) beats one about to start; with
    /// none in progress, the soonest upcoming wins. Nil when none is active.
    func activeCandidate(at now: Date, earlyJoin: TimeInterval = 5 * 60) -> CalendarMeetingCandidate? {
        let active = filter { $0.isActive(at: now, earlyJoin: earlyJoin) }
        let inProgress = active.filter { $0.startDate <= now }
        if let started = inProgress.max(by: { $0.startDate < $1.startDate }) { return started }
        return active.min(by: { $0.startDate < $1.startDate })
    }
}
