import XCTest
@testable import LokalBotV3

/// Calendar-assisted meeting detection: the conferencing-URL parser, event
/// filtering, active-event selection, the browser-meeting decision (the Google
/// Meet reliability fix), repeat-suppression cooldown, titling, and `Meeting`
/// metadata round-tripping. All pure — no EventKit, no real calendar.
final class CalendarDetectionTests: XCTestCase {

    // MARK: - ConferenceURLDetector

    func testDetectsGoogleMeetLink() {
        let url = ConferenceURLDetector.firstMeetingURL(in: "Join here: https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(url?.host, "meet.google.com")
        XCTAssertTrue(ConferenceURLDetector.isMeetingURL(url))
    }

    func testDetectsZoomSubdomain() {
        let url = URL(string: "https://us02web.zoom.us/j/123456789")
        XCTAssertTrue(ConferenceURLDetector.isMeetingURL(url))
    }

    func testDetectsTeamsAndWebex() {
        XCTAssertTrue(ConferenceURLDetector.isMeetingURL(URL(string: "https://teams.microsoft.com/l/meetup-join/x")))
        XCTAssertTrue(ConferenceURLDetector.isMeetingURL(URL(string: "https://acme.webex.com/meet/jane")))
    }

    func testIgnoresNonMeetingURL() {
        XCTAssertNil(ConferenceURLDetector.firstMeetingURL(in: "Agenda at https://docs.example.com/agenda"))
        XCTAssertFalse(ConferenceURLDetector.isMeetingURL(URL(string: "https://example.com/zoom.us-lookalike")))
    }

    func testNoURLInPlainOrEmptyText() {
        XCTAssertNil(ConferenceURLDetector.firstMeetingURL(in: nil))
        XCTAssertNil(ConferenceURLDetector.firstMeetingURL(in: ""))
        XCTAssertNil(ConferenceURLDetector.firstMeetingURL(in: "No links here, just a note."))
    }

    // MARK: - CalendarEventFilter

    private func raw(title: String? = "Sprint Planning",
                     allDay: Bool = false,
                     canceled: Bool = false,
                     declined: Bool = false,
                     free: Bool = false,
                     unavailable: Bool = false,
                     attendees: Bool = true,
                     meetingURL: Bool = true) -> RawCalendarEvent {
        RawCalendarEvent(title: title, isAllDay: allDay, isCanceled: canceled,
                         isDeclinedByMe: declined, availabilityFree: free,
                         availabilityUnavailable: unavailable, hasAttendees: attendees,
                         hasMeetingURL: meetingURL)
    }

    func testRecordableMeetingPasses() {
        XCTAssertTrue(CalendarEventFilter.isRecordableMeeting(raw()))
    }

    func testRejectsAllDayCanceledDeclinedEmptyOOO() {
        XCTAssertFalse(CalendarEventFilter.isRecordableMeeting(raw(allDay: true)), "all-day")
        XCTAssertFalse(CalendarEventFilter.isRecordableMeeting(raw(canceled: true)), "canceled")
        XCTAssertFalse(CalendarEventFilter.isRecordableMeeting(raw(declined: true)), "declined")
        XCTAssertFalse(CalendarEventFilter.isRecordableMeeting(raw(title: "   ")), "blank title")
        XCTAssertFalse(CalendarEventFilter.isRecordableMeeting(raw(title: nil)), "nil title")
        XCTAssertFalse(CalendarEventFilter.isRecordableMeeting(raw(unavailable: true)), "out of office")
    }

    func testRejectsSoloFocusBlock() {
        // Free time, no attendees, no meeting link → a focus/hold block.
        XCTAssertFalse(CalendarEventFilter.isRecordableMeeting(
            raw(free: true, attendees: false, meetingURL: false)))
    }

    func testFreeTimeStillRecordableWithAttendeesOrLink() {
        XCTAssertTrue(CalendarEventFilter.isRecordableMeeting(raw(free: true, attendees: true, meetingURL: false)))
        XCTAssertTrue(CalendarEventFilter.isRecordableMeeting(raw(free: true, attendees: false, meetingURL: true)))
    }

    // MARK: - Active-event selection

    private func candidate(id: String = "evt",
                           start: TimeInterval, end: TimeInterval,
                           url: String? = "https://meet.google.com/abc") -> CalendarMeetingCandidate {
        CalendarMeetingCandidate(
            provider: "test", externalID: id, title: "Meeting",
            startDate: Date(timeIntervalSince1970: start),
            endDate: Date(timeIntervalSince1970: end),
            meetingURL: url.flatMap(URL.init(string:)), sourceCalendarTitle: "Work")
    }

    func testIsActiveWindow() {
        let now = Date(timeIntervalSince1970: 10_000)
        // In progress.
        XCTAssertTrue(candidate(start: 9_700, end: 10_600).isActive(at: now))
        // Within the 5-minute early-join window before start.
        XCTAssertTrue(candidate(start: 10_200, end: 10_900).isActive(at: now))
        // Starts too far out (>5 min).
        XCTAssertFalse(candidate(start: 10_600, end: 11_000).isActive(at: now))
        // Already ended.
        XCTAssertFalse(candidate(start: 9_000, end: 9_900).isActive(at: now))
    }

    func testActiveCandidatePrefersInProgress() {
        let now = Date(timeIntervalSince1970: 10_000)
        let upcoming = candidate(id: "soon", start: 10_200, end: 10_800)   // early-join window
        let live = candidate(id: "live", start: 9_800, end: 10_500)        // in progress
        let result = [upcoming, live].activeCandidate(at: now)
        XCTAssertEqual(result?.externalID, "live")
    }

    func testActiveCandidateNilWhenNoneActive() {
        let now = Date(timeIntervalSince1970: 10_000)
        let past = candidate(id: "past", start: 8_000, end: 9_000)
        let future = candidate(id: "future", start: 12_000, end: 13_000)
        XCTAssertNil([past, future].activeCandidate(at: now))
    }

    // MARK: - Browser-meeting decision (the reliability fix)

    /// A window-title match alone records — current behavior, preserved when
    /// calendar is disabled/denied.
    func testTitleMatchAloneRecords() {
        XCTAssertTrue(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: true, hasOutputAudio: false,
            calendarBacked: false, requireCalendarForBrowser: false))
    }

    /// No title and no calendar → not a meeting (the pre-calendar fallback, and
    /// why a random browser tab is never recorded).
    func testNoTitleNoCalendarDoesNotRecord() {
        XCTAssertFalse(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: false, hasOutputAudio: true,
            calendarBacked: false, requireCalendarForBrowser: false))
    }

    /// Chrome producing audio during an active Meet event records even with no
    /// window-title match — the Google Meet case.
    func testCalendarBackedBrowserAudioRecords() {
        XCTAssertTrue(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: false, hasOutputAudio: true,
            calendarBacked: true, requireCalendarForBrowser: false))
    }

    /// Calendar event alone, with no browser audio, never starts a recording.
    func testCalendarWithoutAudioDoesNotRecord() {
        XCTAssertFalse(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: false, hasOutputAudio: false,
            calendarBacked: true, requireCalendarForBrowser: false))
    }

    func testStrictModeRequiresCalendar() {
        // Title-only is rejected in strict mode...
        XCTAssertFalse(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: true, hasOutputAudio: true,
            calendarBacked: false, requireCalendarForBrowser: true))
        // ...but a calendar-confirmed event with audio is accepted.
        XCTAssertTrue(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: false, hasOutputAudio: true,
            calendarBacked: true, requireCalendarForBrowser: true))
    }

    // MARK: - Repeat-suppression cooldown

    func testSuppressesSameEventWithinCooldown() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(MeetingMatcher.shouldSuppressRepeat(
            eventID: "evt#1", lastEventID: "evt#1",
            lastEndedAt: Date(timeIntervalSince1970: 9_900), now: now, cooldown: 300))
    }

    func testAllowsSameEventAfterCooldown() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(MeetingMatcher.shouldSuppressRepeat(
            eventID: "evt#1", lastEventID: "evt#1",
            lastEndedAt: Date(timeIntervalSince1970: 9_600), now: now, cooldown: 300))
    }

    func testAllowsDifferentEventAndFirstRecording() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(MeetingMatcher.shouldSuppressRepeat(
            eventID: "evt#2", lastEventID: "evt#1",
            lastEndedAt: Date(timeIntervalSince1970: 9_990), now: now, cooldown: 300), "different event")
        XCTAssertFalse(MeetingMatcher.shouldSuppressRepeat(
            eventID: "evt#1", lastEventID: nil, lastEndedAt: nil, now: now, cooldown: 300), "no prior recording")
    }

    // MARK: - Titling

    func testRecordingTitlePrefersCalendar() {
        XCTAssertEqual(MeetingMatcher.recordingTitle(
            calendarTitle: "Weekly Sync", useCalendarTitles: true, appName: "Google Chrome"), "Weekly Sync")
    }

    func testRecordingTitleFallsBackWhenTitlesOff() {
        XCTAssertEqual(MeetingMatcher.recordingTitle(
            calendarTitle: "Weekly Sync", useCalendarTitles: false, appName: "Google Chrome"), "Google Chrome meeting")
    }

    func testRecordingTitleFallsBackWhenNoCalendarTitle() {
        XCTAssertEqual(MeetingMatcher.recordingTitle(
            calendarTitle: "  ", useCalendarTitles: true, appName: "Zoom"), "Zoom meeting")
        XCTAssertEqual(MeetingMatcher.recordingTitle(
            calendarTitle: nil, useCalendarTitles: true, appName: nil), "Manual recording")
    }

    // MARK: - Confidence

    func testConfidence() {
        XCTAssertEqual(MeetingMatcher.confidence(hasApp: true, hasCalendar: true), .high)
        XCTAssertEqual(MeetingMatcher.confidence(hasApp: true, hasCalendar: false), .medium)
        XCTAssertEqual(MeetingMatcher.confidence(hasApp: false, hasCalendar: true), .low)
    }

    // MARK: - In-meeting policy (start / continue / stop)

    /// Regression: once recording starts, our own mic recorder keeps the global
    /// "mic in use" flag true. The continue decision must ignore it and key off
    /// the meeting app's OWN audio — otherwise the meeting never reads as ended
    /// and recording never stops.
    func testRecordingMicDoesNotKeepMeetingAliveWhenAppAudioStops() {
        XCTAssertFalse(MeetingMatcher.isMeetingOngoing(
            hasActiveSession: true, hasRunningMeetingApp: true, hasContinuingApp: true,
            micInUse: true, appAudioActive: false, calendarBackedBrowserWithAudio: false),
            "global mic (our own recorder) must not keep an otherwise-silent meeting open")
    }

    func testContinuesWhileAppAudioActive() {
        XCTAssertTrue(MeetingMatcher.isMeetingOngoing(
            hasActiveSession: true, hasRunningMeetingApp: true, hasContinuingApp: true,
            micInUse: false, appAudioActive: true, calendarBackedBrowserWithAudio: false))
    }

    func testEndsWhenAppGoneRegardlessOfMic() {
        XCTAssertFalse(MeetingMatcher.isMeetingOngoing(
            hasActiveSession: true, hasRunningMeetingApp: false, hasContinuingApp: false,
            micInUse: true, appAudioActive: true, calendarBackedBrowserWithAudio: false))
    }

    func testStartsOnMeetingAppPlusMic() {
        XCTAssertTrue(MeetingMatcher.isMeetingOngoing(
            hasActiveSession: false, hasRunningMeetingApp: true, hasContinuingApp: false,
            micInUse: true, appAudioActive: false, calendarBackedBrowserWithAudio: false))
    }

    func testDoesNotStartWithoutMicOrCalendarAudio() {
        XCTAssertFalse(MeetingMatcher.isMeetingOngoing(
            hasActiveSession: false, hasRunningMeetingApp: true, hasContinuingApp: false,
            micInUse: false, appAudioActive: false, calendarBackedBrowserWithAudio: false))
    }

    func testStartsCalendarBackedBrowserOnOutputAudio() {
        XCTAssertTrue(MeetingMatcher.isMeetingOngoing(
            hasActiveSession: false, hasRunningMeetingApp: true, hasContinuingApp: false,
            micInUse: false, appAudioActive: false, calendarBackedBrowserWithAudio: true))
    }

    func testContinuesViaContinuingAppAfterRunningAppDropsOut() {
        XCTAssertTrue(MeetingMatcher.isMeetingOngoing(
            hasActiveSession: true, hasRunningMeetingApp: false, hasContinuingApp: true,
            micInUse: false, appAudioActive: true, calendarBackedBrowserWithAudio: false))
    }

    // MARK: - Provider access gating (denied → no candidates)

    func testProviderYieldsNothingWhenAccessDenied() {
        let now = Date(timeIntervalSince1970: 10_000)
        let live = candidate(start: 9_800, end: 10_500)
        XCTAssertNil(FakeCalendarProvider(status: .denied, candidates: [live]).activeCandidate(now: now))
        XCTAssertNil(FakeCalendarProvider(status: .notDetermined, candidates: [live]).activeCandidate(now: now))
        XCTAssertEqual(
            FakeCalendarProvider(status: .fullAccess, candidates: [live]).activeCandidate(now: now)?.externalID,
            live.externalID)
    }

    // MARK: - Meeting metadata persistence

    private func iso() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }

    /// A meta.json written before calendar support still decodes (calendar
    /// fields default to nil).
    func testDecodesLegacyMeetingWithoutCalendarFields() throws {
        let json = #"""
        {"id":"7E57C0DE-0000-4000-8000-000000000001","title":"Standup","appName":"Zoom","startedAt":"2026-06-16T09:00:00Z","relativePath":"meetings/2026/06/16-standup","hasSystemTrack":true}
        """#
        let (_, decoder) = iso()
        let meeting = try decoder.decode(Meeting.self, from: Data(json.utf8))
        XCTAssertEqual(meeting.title, "Standup")
        XCTAssertTrue(meeting.hasSystemTrack)
        XCTAssertNil(meeting.calendarProvider)
        XCTAssertNil(meeting.calendarEventID)
        XCTAssertNil(meeting.scheduledStartAt)
        XCTAssertNil(meeting.meetingURL)
    }

    /// Calendar provenance round-trips through the same ISO-8601 codec
    /// StorageManager uses for meta.json.
    func testCalendarFieldsRoundTrip() throws {
        var meeting = Meeting(
            id: UUID(), title: "Sprint Planning", appName: "Google Chrome",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            relativePath: "meetings/2026/06/16-sprint-planning")
        meeting.calendarProvider = "eventkit"
        meeting.calendarEventID = "evt#1700000000"
        meeting.calendarTitle = "Sprint Planning"
        meeting.scheduledStartAt = Date(timeIntervalSince1970: 1_700_000_000)
        meeting.scheduledEndAt = Date(timeIntervalSince1970: 1_700_003_600)
        meeting.meetingURL = URL(string: "https://meet.google.com/abc-defg-hij")

        let (encoder, decoder) = iso()
        let decoded = try decoder.decode(Meeting.self, from: encoder.encode(meeting))
        XCTAssertEqual(decoded, meeting)
    }

    /// Manual recordings (no calendar) keep their old, calendar-free JSON shape:
    /// nil optionals are omitted, never written as null keys.
    func testManualMeetingOmitsCalendarKeys() throws {
        let meeting = Meeting(
            id: UUID(), title: "Manual recording", appName: "Manual",
            startedAt: Date(timeIntervalSince1970: 1), endedAt: nil,
            relativePath: "meetings/2026/06/16-manual")
        let (encoder, _) = iso()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(meeting)) as? [String: Any])
        XCTAssertNil(object["calendarProvider"])
        XCTAssertNil(object["calendarEventID"])
        XCTAssertNil(object["meetingURL"])
    }
}

/// In-memory `CalendarEventProviding` for the matching tests — canned status
/// and candidates, no EventKit.
private final class FakeCalendarProvider: CalendarEventProviding {
    let authorizationStatus: CalendarAuthorizationStatus
    private let candidates: [CalendarMeetingCandidate]

    init(status: CalendarAuthorizationStatus, candidates: [CalendarMeetingCandidate]) {
        self.authorizationStatus = status
        self.candidates = candidates
    }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        completion(authorizationStatus == .fullAccess)
    }

    func meetingCandidates(now: Date) -> [CalendarMeetingCandidate] { candidates }
}
