import Foundation

/// EventKit-independent snapshot of the handful of fields meeting-filtering
/// needs, so the filter rules are unit-testable without a real calendar store.
struct RawCalendarEvent: Equatable {
    var title: String?
    var isAllDay: Bool
    var isCanceled: Bool
    /// The current user declined this invite.
    var isDeclinedByMe: Bool
    /// `availability == .free` — focus/hold blocks usually carry this.
    var availabilityFree: Bool
    /// `availability == .unavailable` — out-of-office.
    var availabilityUnavailable: Bool
    var hasAttendees: Bool
    var hasMeetingURL: Bool
}

enum CalendarEventFilter {
    /// A recordable meeting: a real title, and not one of the non-meeting shapes
    /// — all-day, cancelled, declined, out-of-office, or a solo focus/hold block
    /// (free time with no attendees and no conferencing link).
    static func isRecordableMeeting(_ event: RawCalendarEvent) -> Bool {
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return false }
        if event.isAllDay || event.isCanceled || event.isDeclinedByMe { return false }
        if event.availabilityUnavailable { return false }
        if event.availabilityFree && !event.hasAttendees && !event.hasMeetingURL { return false }
        return true
    }
}
