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

    /// A live recording backed by one calendar event should split immediately
    /// when the active calendar event changes. This prevents back-to-back
    /// meetings from being merged during the stop debounce.
    static func shouldSplitForCalendarHandoff(activeEventID: String?,
                                              nextEventID: String?) -> Bool {
        guard let activeEventID, let nextEventID else { return false }
        return activeEventID != nextEventID
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
        return meetingTitle(for: appName)
    }

    /// "<App> meeting", without doubling a trailing "meeting" in the app name.
    static func meetingTitle(for appName: String) -> String {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Meeting" }
        return trimmed.localizedCaseInsensitiveContains("meeting")
            && trimmed.lowercased().hasSuffix("meeting")
            ? trimmed
            : "\(trimmed) meeting"
    }

    /// Whether the detector should treat a meeting as in progress this tick.
    ///
    /// `appAudioActive` is the *meeting app's own* audio I/O (input or output).
    /// It deliberately replaces the global "mic in use" flag: once we start
    /// recording, our own mic capture keeps the default input device "running
    /// somewhere", and before recording a global mic check can belong to a
    /// different app entirely. Start and continue both key off the selected app's
    /// own audio signal; calendar-backed browsers may also start from output
    /// audio found in their helper process.
    static func isMeetingOngoing(hasActiveSession: Bool,
                                 hasRunningMeetingApp: Bool,
                                 hasContinuingApp: Bool,
                                 startAudioActive: Bool,
                                 appAudioActive: Bool,
                                 calendarBackedBrowserWithAudio: Bool) -> Bool {
        let canStart = !hasActiveSession && hasRunningMeetingApp
            && (startAudioActive || calendarBackedBrowserWithAudio)
        let canContinue = hasActiveSession && (hasRunningMeetingApp || hasContinuingApp)
            && appAudioActive
        return canStart || canContinue
    }
}
