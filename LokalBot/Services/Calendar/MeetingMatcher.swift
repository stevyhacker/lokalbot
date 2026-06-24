import Foundation

/// What the detector concluded about the current moment: the app/browser that
/// will be captured, the calendar event it lines up with (if any), how sure we
/// are, and why. A calendar event *alone* never produces a recordable context —
/// only an app/audio signal does — so this is always backed by something to record.
struct MeetingDetectionContext: Equatable {
    enum Confidence: Int, Comparable {
        case low, medium, high
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let detectedApp: MeetingDetector.DetectedApp?
    let calendarEvent: CalendarMeetingCandidate?
    let confidence: Confidence
    let reason: String
}

/// The matching layer between detection and recording. Pure policy — no
/// EventKit, AppKit, or Core Audio — so every rule here is unit-testable.
enum MeetingMatcher {
    /// Whether a browser that is producing meeting-like signal should count as a
    /// meeting. `calendarBacked` already folds in "calendar enabled AND an active
    /// event with a conferencing URL". This is the crux of reliable browser
    /// detection: a generic/empty window title (or missing Accessibility) no
    /// longer hides a Google Meet when the calendar confirms it — and the
    /// stricter mode refuses browser auto-recording without that confirmation.
    static func browserCountsAsMeeting(titleMatchesMarker: Bool,
                                       hasOutputAudio: Bool,
                                       calendarBacked: Bool,
                                       requireCalendarForBrowser: Bool) -> Bool {
        if requireCalendarForBrowser { return calendarBacked && hasOutputAudio }
        return titleMatchesMarker || (calendarBacked && hasOutputAudio)
    }

    static func confidence(hasApp: Bool, hasCalendar: Bool) -> MeetingDetectionContext.Confidence {
        switch (hasApp, hasCalendar) {
        case (true, true): return .high
        case (true, false): return .medium
        case (false, _): return .low
        }
    }

    /// Suppress an auto-start that would re-record the same calendar event right
    /// after one for it ended — debounced browser-helper PID churn, brief audio
    /// drops, a detector tick racing a manual stop. A genuinely new occurrence
    /// has a different `externalID`, so it is never blocked.
    static func shouldSuppressRepeat(eventID: String?,
                                     lastEventID: String?,
                                     lastEndedAt: Date?,
                                     now: Date,
                                     cooldown: TimeInterval) -> Bool {
        guard let eventID, let lastEventID, let lastEndedAt, eventID == lastEventID else { return false }
        return now.timeIntervalSince(lastEndedAt) < cooldown
    }

    /// The recording title: the calendar event's title when titling is on and it
    /// has one, else the app-derived "<App> meeting", else "Manual recording".
    static func recordingTitle(calendarTitle: String?, useCalendarTitles: Bool, appName: String?) -> String {
        if useCalendarTitles {
            let title = calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !title.isEmpty { return title }
        }
        guard let appName, !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Manual recording"
        }
        return AppState.meetingTitle(for: appName)
    }
}
