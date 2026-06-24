import EventKit
import Foundation

/// `CalendarEventProviding` backed by the system calendar via EventKit. Reads
/// only — no Google/Microsoft OAuth (v1): anything synced into Apple Calendar
/// (Google, Exchange, iCloud) is visible here all the same.
///
/// `ObservableObject` so the settings UI reflects permission changes; the data
/// methods stay non-isolated so the (non-`@MainActor`) detector can read them
/// straight from its tick on the main thread.
final class EventKitCalendarEventProvider: ObservableObject, CalendarEventProviding {
    /// Look-around window: a meeting you joined up to 15 min late still matches,
    /// and one starting within 90 min is visible for early detection.
    static let lookBehind: TimeInterval = 15 * 60
    static let lookAhead: TimeInterval = 90 * 60
    /// Re-fetch at most this often — EventKit ticks (mic toggles, audio blips)
    /// shouldn't hammer the store; meetings don't change on a 30 s scale.
    static let cacheTTL: TimeInterval = 30

    @Published private(set) var authorizationStatus: CalendarAuthorizationStatus
    private let store: EKEventStore
    private var cache: (fetchedAt: Date, candidates: [CalendarMeetingCandidate])?

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
        authorizationStatus = Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.cache = nil
                self?.refreshAuthorizationStatus()
                completion(granted)
            }
        }
    }

    /// Re-reads the TCC state (it can change in System Settings with no
    /// notification) and republishes only on a real change.
    func refreshAuthorizationStatus() {
        let latest = Self.map(EKEventStore.authorizationStatus(for: .event))
        if latest != authorizationStatus { authorizationStatus = latest }
    }

    func meetingCandidates(now: Date) -> [CalendarMeetingCandidate] {
        guard authorizationStatus == .fullAccess else { return [] }
        if let cache, now >= cache.fetchedAt, now.timeIntervalSince(cache.fetchedAt) < Self.cacheTTL {
            return cache.candidates
        }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-Self.lookBehind),
            end: now.addingTimeInterval(Self.lookAhead),
            calendars: nil)
        let candidates = store.events(matching: predicate)
            .compactMap(Self.candidate(from:))
            .sorted { $0.startDate < $1.startDate }
        cache = (now, candidates)
        return candidates
    }

    // MARK: - Mapping

    /// Map an `EKEvent` to a recordable candidate, applying ``CalendarEventFilter``.
    /// Nil for non-meetings (all-day, cancelled, declined, OOO, focus blocks,
    /// untitled) or events missing a start/end.
    static func candidate(from event: EKEvent) -> CalendarMeetingCandidate? {
        let meetingURL = ConferenceURLDetector.firstMeetingURL(in: event.url?.absoluteString)
            ?? ConferenceURLDetector.firstMeetingURL(in: event.location)
            ?? ConferenceURLDetector.firstMeetingURL(in: event.notes)
        let raw = RawCalendarEvent(
            title: event.title,
            isAllDay: event.isAllDay,
            isCanceled: event.status == .canceled,
            isDeclinedByMe: declinedByCurrentUser(event),
            availabilityFree: event.availability == .free,
            availabilityUnavailable: event.availability == .unavailable,
            hasAttendees: event.attendees?.isEmpty == false,
            hasMeetingURL: meetingURL != nil)
        guard CalendarEventFilter.isRecordableMeeting(raw),
              let start = event.startDate, let end = event.endDate,
              let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        return CalendarMeetingCandidate(
            provider: "eventkit",
            externalID: occurrenceID(event, start: start),
            title: title,
            startDate: start,
            endDate: end,
            meetingURL: meetingURL,
            sourceCalendarTitle: event.calendar?.title)
    }

    /// Per-occurrence id: the event id alone is shared across a recurring
    /// series, so fold in the occurrence start to keep occurrences distinct.
    private static func occurrenceID(_ event: EKEvent, start: Date) -> String {
        let base = event.eventIdentifier ?? event.calendarItemIdentifier
        return "\(base)#\(Int(start.timeIntervalSince1970))"
    }

    private static func declinedByCurrentUser(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    private static func map(_ status: EKAuthorizationStatus) -> CalendarAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        @unknown default: return .denied
        }
    }
}
