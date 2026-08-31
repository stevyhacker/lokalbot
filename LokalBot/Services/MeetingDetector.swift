import AppKit
import CoreAudio

/// Detects meeting start/end by combining two signals (design doc §2.1):
///   1. A known meeting app is running.
///   2. The default input device (mic) is in use system-wide.
/// Start fires immediately; end fires after a debounce so brief mic drops
/// (e.g. switching AirPods) don't split a meeting in two.
///
/// Reacts instantly via Core Audio property listeners (mic in use, default
/// device change) and NSWorkspace launch/quit notifications; a slow safety
/// poll (10 s) covers what has no notification — browser tab titles.
final class MeetingDetector {

    struct DetectedApp: Equatable {
        let name: String
        let bundleID: String
        let pid: pid_t
    }

    /// Known native meeting apps.
    static let knownApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.webex.meetingmanager": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.apple.FaceTime": "FaceTime",
    ]

    /// Native bundles whose newly-started output is a strong meeting signal on
    /// its own. Broader communication apps (Slack/Teams/FaceTime) can make short
    /// non-meeting sounds, so the audio monitor only auto-records those when an
    /// active calendar meeting backs the signal; the detector still picks them
    /// up on its own, but only once their audio has lasted
    /// `nativeAudioMinimumConfirmationDuration` (see
    /// `requiresSustainedAudioForStart`).
    private static let highConfidenceNativeAudioBundles: Set<String> = [
        "us.zoom.xos",
        "com.webex.meetingmanager",
        "Cisco-Systems.Spark",
    ]

    static func shouldAutoRecordNativeAudioMonitor(bundleID: String, calendarBacked: Bool) -> Bool {
        highConfidenceNativeAudioBundles.contains(bundleID) || calendarBacked
    }

    /// Minimum duration a broad communication app's audio must sustain before
    /// it counts as a meeting start. Confirmation is inclusive at exactly this
    /// duration; shorter candidates are rejected. A message ding or launch blip
    /// opens an output stream just as a call does, so the value must sit above
    /// the measured transient range.
    ///
    /// Twelve seconds leaves a 1.2 s margin above the longest observed short
    /// false start (10.8 s) while keeping real-call start latency bounded close
    /// to the previous ten-second gate. The other short samples were 0.2 s and
    /// 7.6 s, reconstructed against the 15 s stop debounce.
    /// It deliberately does not try to cover the two longer ones (21.1 s and
    /// 48.9 s) — those were an output stream held open while emitting digital
    /// silence (`peakRMS=0.000000` throughout), which no threshold separates
    /// from a real call without also refusing to record one. That case is a
    /// detection-side defect rather than a timing one; see the note on
    /// `alwaysOpenAudioBundles`.
    static let nativeAudioMinimumConfirmationDuration: TimeInterval = 12

    /// How long the confirmation window survives a candidate producing no
    /// output audio at all, before `nativeAudioMinimumConfirmationDuration`
    /// has elapsed.
    ///
    /// `detectRunningMeetingApp` requires current audio (`requireAudio: true`)
    /// so the confirmation window is watching a signal that is not "is a call
    /// happening" but "is the remote side making sound right now" — and in a
    /// real conversation the remote side spends much of its time listening.
    /// Without this, the very first quiet turn dropped the candidate entirely
    /// (not merely the elapsed time — the app stopped being detected as
    /// running at all), and a live 12-second window essentially never
    /// completed: six consecutive real attempts on 2026-08-26 each failed
    /// after 4.2–12.7 s, two of them past the 12 s mark itself.
    ///
    /// Six seconds is half the confirmation window on purpose: a single blip
    /// followed by silence past this tolerance still resets — the case
    /// `nativeAudioMinimumConfirmationDuration` exists to guard against — while
    /// audio recurring at least this often lets a real conversation complete
    /// the window. It only ever bridges a gap in evidence; it never invents
    /// evidence on its own, so this cannot make an idle-but-open app confirm.
    static let nativeAudioConfirmationGapTolerance: TimeInterval = 6

    /// Bundles inside a meeting app's namespace that hold their Core Audio
    /// streams open for the app's whole lifetime, so their state carries no
    /// information about whether a call is running.
    ///
    /// Measured with Teams launched and idle, 20 samples over 20 s:
    /// `com.microsoft.teams2.modulehost` reported `isRunningOutput` *and*
    /// `isRunningInput` true in 20/20, while all three
    /// `com.microsoft.teams2.helper` processes reported false in 60/60. Any
    /// detection rule that matches the whole namespace therefore sees Teams as
    /// permanently in a meeting, and neither a longer window nor the microphone
    /// can tell the two apart. Capture must still be free to tap these — a tap
    /// on a silent process simply records nothing until audio starts — so this
    /// belongs to the detection question alone.
    static let alwaysOpenAudioBundles: Set<String> = [
        "com.microsoft.teams2.modulehost",
    ]

    /// Whether an audio process says anything about a call being under way.
    static func carriesMeetingSignal(bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        return !alwaysOpenAudioBundles.contains(bundleID.lowercased())
    }

    /// Whether this app's audio must survive
    /// `nativeAudioMinimumConfirmationDuration` before a recording starts.
    /// Dedicated conferencing bundles and
    /// calendar-backed starts stay instant, and browsers are gated by their own
    /// title/calendar rules, so they never wait here.
    static func requiresSustainedAudioForStart(bundleID: String, calendarBacked: Bool) -> Bool {
        guard knownApps[bundleID] != nil else { return false }
        return !shouldAutoRecordNativeAudioMonitor(bundleID: bundleID, calendarBacked: calendarBacked)
    }

    /// Browsers whose focused-window title we inspect for web meetings
    /// (needs Accessibility; silently skipped without it).
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox",
    ]
    private static let webMeetingMarkers = ["Meet – ", "Meet - ", "meet.google.com", "Jitsi", "Whereby"]

    var onMeetingStarted: ((MeetingDetectionContext) -> Void)?
    var onMeetingSwitched: ((MeetingDetectionContext) -> Void)?
    var onMeetingEnded: (() -> Void)?
    var stopDebounce: TimeInterval = AppSettings.defaultStopDebounceSeconds
    /// Extra grace before stopping while a calendar-backed meeting is still in
    /// its scheduled window — brief audio drops mid-meeting shouldn't end it.
    static let calendarBackedGrace: TimeInterval = 180

    // Calendar-assisted detection, synced from `AppSettings` by `AppState`.
    var calendar: CalendarEventProviding?
    var calendarEnabled = false
    var requireCalendarForBrowser = false

    private(set) var activeApp: DetectedApp?
    /// The calendar event matched when the current session started — drives the
    /// extended stop grace and is carried into the recording's metadata.
    private var activeCalendarEvent: CalendarMeetingCandidate?
    private var timer: Timer?
    private var pendingStop: DispatchWorkItem?
    /// The start candidate still waiting out
    /// `nativeAudioMinimumConfirmationDuration`: when its audio was first seen,
    /// and when it was last seen — the second lets a normal conversational gap
    /// (the remote side listening rather than talking) survive without
    /// restarting the window. See `nativeAudioConfirmationGapTolerance`.
    private var startConfirmation = MeetingMatcher.StartConfirmationState()
    /// Last logged start-decision state, so the 10 s safety poll does not
    /// repeat the same line forever. Diagnostics only.
    private var lastLoggedStartState: String?
    private var pendingStartRecheck: DispatchWorkItem?
    private var workspaceObservers: [NSObjectProtocol] = []

    private var micListener: AudioObjectPropertyListenerBlock?
    private var listenedDevice = AudioObjectID(kAudioObjectUnknown)
    /// Added once — re-adding on every re-arm multiplies Core Audio
    /// callbacks (each mic open/close then fans out into a tick storm).
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?

    /// Core Audio process enumeration is comparatively expensive and several
    /// meeting subsystems ask for the same answer in one detector/poller turn.
    /// Keep a very short-lived snapshot so detection, helper handoff, and media
    /// pausing share one system query without making process state feel stale.
    private static let processSnapshotLock = NSLock()
    private static var processSnapshot: (capturedAt: Date, processes: [AudioProcess])?
    private static let processSnapshotLifetime: TimeInterval = 0.35

    func start() {
        guard timer == nil else { return }
        // Safety-net poll (browser titles have no change notification).
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Instant signals: mic state, default-device change, app launch/quit.
        armMicListener()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Self.invalidateAudioProcessSnapshot()
                self?.tick()
            }
            workspaceObservers.append(observer)
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pendingStop?.cancel()
        pendingStop = nil
        clearPendingStart()
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
        workspaceObservers.removeAll()
        disarmAll()
    }

    /// Listener on the default input device's "running somewhere" property,
    /// re-armed whenever the default input device itself changes.
    private func armMicListener() {
        disarmMicListener()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if deviceChangeListener == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.armMicListener()   // device changed → re-arm on the new one
                    self?.tick()
                }
            }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, .main, block)
            deviceChangeListener = block
        }

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return }
        var runningAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let micBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.tick() }
        }
        AudioObjectAddPropertyListenerBlock(deviceID, &runningAddr, .main, micBlock)
        micListener = micBlock
        listenedDevice = deviceID
    }

    private func disarmMicListener() {
        guard let micListener, listenedDevice != kAudioObjectUnknown else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(listenedDevice, &addr, .main, micListener)
        self.micListener = nil
        listenedDevice = AudioObjectID(kAudioObjectUnknown)
    }

    /// Full teardown including the default-device listener; only called
    /// from `stop()`. `armMicListener()` calls `disarmMicListener()` (not
    /// this) to keep the device-change listener installed across re-arms.
    private func disarmAll() {
        disarmMicListener()
        if let deviceChangeListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &addr, .main, deviceChangeListener)
            self.deviceChangeListener = nil
        }
    }

    private func tick() {
        let now = Date()
        let running = NSWorkspace.shared.runningApplications
        let calendarEvent = calendarEnabled ? calendar?.activeCandidate(now: now) : nil

        if let currentApp = activeApp {
            let continuingApp = Self.continuingApp(currentApp, in: running)
            let appAudioActive = continuingApp.map { Self.hasAudio(for: $0) } ?? false
            let isBrowserApp = continuingApp.map { Self.browsers.contains($0.bundleID) } ?? false
            let calendarBackedBrowserWithAudio = isBrowserApp
                && calendarEnabled
                && calendarEvent?.meetingURL != nil
                && appAudioActive
            let inMeeting = MeetingMatcher.isMeetingOngoing(
                hasActiveSession: true,
                hasRunningMeetingApp: false,
                hasContinuingApp: continuingApp != nil,
                startAudioActive: false,
                appAudioActive: appAudioActive,
                calendarBackedBrowserWithAudio: calendarBackedBrowserWithAudio)

            guard inMeeting, let app = continuingApp else {
                if let replacementApp = Self.detectRunningMeetingApp(
                    in: running,
                    calendarEvent: calendarEvent,
                    calendarEnabled: calendarEnabled,
                    requireCalendarForBrowser: requireCalendarForBrowser) {
                    pendingStop?.cancel()
                    pendingStop = nil
                    let previousApp = activeApp
                    activeApp = replacementApp
                    activeCalendarEvent = calendarEvent
                    if previousApp != replacementApp {
                        onMeetingSwitched?(MeetingDetectionContext(
                            detectedApp: replacementApp,
                            calendarEvent: calendarEvent,
                            confidence: MeetingMatcher.confidence(
                                hasApp: true, hasCalendar: calendarEvent != nil),
                            reason: "meeting-app-handoff"))
                    }
                    return
                }
                scheduleStopIfNeeded(now: now)
                return
            }

            pendingStop?.cancel()
            pendingStop = nil
            let previousEventID = activeCalendarEvent?.externalID
            activeApp = app
            if let calendarEvent {
                activeCalendarEvent = calendarEvent
                if MeetingMatcher.shouldSplitForCalendarHandoff(
                    activeEventID: previousEventID,
                    nextEventID: calendarEvent.externalID) {
                    onMeetingSwitched?(MeetingDetectionContext(
                        detectedApp: app,
                        calendarEvent: calendarEvent,
                        confidence: MeetingMatcher.confidence(hasApp: true, hasCalendar: true),
                        reason: "calendar-handoff"))
                }
            }
            return
        }

        let runningMeetingApp = Self.detectRunningMeetingApp(
            in: running,
            calendarEvent: calendarEvent,
            calendarEnabled: calendarEnabled,
            requireCalendarForBrowser: requireCalendarForBrowser)
        let isBrowserApp = runningMeetingApp.map { Self.browsers.contains($0.bundleID) } ?? false
        let calendarBackedBrowser = isBrowserApp && calendarEnabled && calendarEvent?.meetingURL != nil
        // Both start and continuation hinge on the selected app's OWN audio
        // (input or output), not the global mic flag. A global mic check can
        // belong to Dictation/QuickTime/another meeting app while a known meeting
        // app is merely idle in the background.
        let startAudioActive = runningMeetingApp.map { Self.hasAudio(for: $0) } ?? false
        let calendarBackedBrowserWithAudio = calendarBackedBrowser
            && (runningMeetingApp.map { Self.hasOutputAudio(for: $0) } ?? false)
        let inMeeting = MeetingMatcher.isMeetingOngoing(
            hasActiveSession: false,
            hasRunningMeetingApp: runningMeetingApp != nil,
            hasContinuingApp: false,
            startAudioActive: startAudioActive,
            appAudioActive: false,
            calendarBackedBrowserWithAudio: calendarBackedBrowserWithAudio)

        if inMeeting, let app = runningMeetingApp {
            guard startConfirmed(app: app, calendarBacked: calendarEvent != nil, now: now) else { return }
            logStartState("detector confirmed app=\(app.bundleID)")
            beginMeeting(app: app, calendarEvent: calendarEvent)
            return
        }

        // No fresh output audio this instant. `detectRunningMeetingApp`
        // requires it, so this branch also covers the remote side simply
        // listening rather than talking — the app itself may still be mid-call.
        // A candidate already inside its confirmation window gets a grace
        // period before that silence is read as the call having ended.
        if let pendingStart = startConfirmation.window,
           Self.requiresSustainedAudioForStart(
               bundleID: pendingStart.bundleID, calendarBacked: calendarEvent != nil),
           let app = Self.nativeApp(bundleID: pendingStart.bundleID, in: running) {
            switch MeetingMatcher.startConfirmationGapOutcome(
                firstSeenAt: pendingStart.firstSeenAt,
                lastAudioSeenAt: pendingStart.lastAudioSeenAt,
                now: now,
                gapTolerance: Self.nativeAudioConfirmationGapTolerance,
                minimumDuration: Self.nativeAudioMinimumConfirmationDuration) {
            case .confirmed:
                logStartState("detector confirmed app=\(app.bundleID) (bridged gap)")
                beginMeeting(app: app, calendarEvent: calendarEvent)
                return
            case .stillWaiting:
                let elapsed = now.timeIntervalSince(pendingStart.firstSeenAt)
                let gapRemaining = Self.nativeAudioConfirmationGapTolerance
                    - now.timeIntervalSince(pendingStart.lastAudioSeenAt)
                scheduleStartConfirmationRecheck(
                    after: min(gapRemaining, Self.nativeAudioMinimumConfirmationDuration - elapsed),
                    generation: pendingStart.generation)
                return
            case .abandoned:
                break
            }
        }

        logStartState(
            runningMeetingApp.map {
                "detector idle app=\($0.bundleID) audio=\(startAudioActive) "
                    + "calendar=\(calendarEvent != nil)"
            } ?? "detector idle app=none")
        clearPendingStart()
    }

    private func beginMeeting(app: DetectedApp, calendarEvent: CalendarMeetingCandidate?) {
        clearPendingStart(loggingLoss: false)
        pendingStop?.cancel()
        pendingStop = nil
        activeApp = app
        activeCalendarEvent = calendarEvent
        onMeetingStarted?(MeetingDetectionContext(
            detectedApp: app,
            calendarEvent: calendarEvent,
            confidence: MeetingMatcher.confidence(hasApp: true, hasCalendar: calendarEvent != nil),
            reason: "detector"))
    }

    /// Tracks how long the start candidate's audio has been continuously
    /// present and answers whether it may start a recording yet. Candidates
    /// that need no confirmation answer true on their first tick.
    /// Called only when `app` has fresh output audio this tick. Advances the
    /// window's evidence clock; `tick()` separately decides whether a gap
    /// since the last call may still keep this same window alive.
    private func startConfirmed(app: DetectedApp, calendarBacked: Bool, now: Date) -> Bool {
        guard Self.requiresSustainedAudioForStart(
            bundleID: app.bundleID, calendarBacked: calendarBacked) else { return true }
        let startedNewWindow = startConfirmation.observeAudio(
            bundleID: app.bundleID,
            at: now,
            gapTolerance: Self.nativeAudioConfirmationGapTolerance)
        if startedNewWindow {
            cancelPendingStartRecheck()
            lokalbotLog(
                "detector waiting for sustained audio app=\(app.bundleID) "
                    + "needs=\(Int(Self.nativeAudioMinimumConfirmationDuration))s")
        }
        guard let pendingStart = startConfirmation.window else { return false }
        if MeetingMatcher.sustainedAudioConfirmed(
            firstSeenAt: pendingStart.firstSeenAt,
            now: now,
            minimumDuration: Self.nativeAudioMinimumConfirmationDuration) {
            return true
        }
        // Ticks are event-driven plus a slow safety poll, so a real meeting
        // would otherwise wait for the next poll boundary instead of starting
        // the moment the minimum duration elapses.
        let elapsed = now.timeIntervalSince(pendingStart.firstSeenAt)
        scheduleStartConfirmationRecheck(
            after: Self.nativeAudioMinimumConfirmationDuration - elapsed,
            generation: pendingStart.generation)
        return false
    }

    /// Logs a start-decision state once per change. The detector otherwise
    /// says nothing at all unless it starts a recording, so "it did not fire"
    /// has no evidence behind it.
    private func logStartState(_ state: String) {
        guard lastLoggedStartState != state else { return }
        lastLoggedStartState = state
        lokalbotLog(state)
    }

    private func scheduleStartConfirmationRecheck(after delay: TimeInterval,
                                                  generation: UInt64) {
        guard startConfirmation.acceptsRecheck(for: generation),
              pendingStartRecheck == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.startConfirmation.acceptsRecheck(for: generation) else { return }
            self.pendingStartRecheck = nil
            self.tick()
        }
        pendingStartRecheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.25), execute: work)
    }

    /// `loggingLoss` is false when the candidate is being cleared because it
    /// just started a meeting — that clears the same state but is a success,
    /// not a loss, and must not log as one.
    private func clearPendingStart(loggingLoss: Bool = true) {
        if loggingLoss, let pendingStart = startConfirmation.window {
            lokalbotLog(
                "detector lost the audio it was waiting on app=\(pendingStart.bundleID) "
                    + "after=\(String(format: "%.1fs", Date().timeIntervalSince(pendingStart.firstSeenAt)))")
        }
        startConfirmation.clear()
        cancelPendingStartRecheck()
    }

    private func cancelPendingStartRecheck() {
        pendingStartRecheck?.cancel()
        pendingStartRecheck = nil
    }

    private static func detectRunningMeetingApp(
        in running: [NSRunningApplication],
        calendarEvent: CalendarMeetingCandidate?,
        calendarEnabled: Bool,
        requireCalendarForBrowser: Bool
    ) -> DetectedApp? {
        nativeMeetingApp(in: running, requireAudio: true)
            ?? browserMeeting(in: running,
                              calendarEvent: calendarEvent,
                              calendarEnabled: calendarEnabled,
                              requireCalendarForBrowser: requireCalendarForBrowser)
    }

    private func scheduleStopIfNeeded(now: Date) {
        guard activeApp != nil, pendingStop == nil else { return }
        // Never stop because calendar time ended — only audio does. While the
        // matched event is still in its window, extend the debounce so brief
        // drops don't split a scheduled meeting.
        let calendarStillActive = activeCalendarEvent?.isActive(at: now) ?? false
        let debounce = calendarStillActive ? max(stopDebounce, Self.calendarBackedGrace) : stopDebounce
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.activeApp = nil
            self.activeCalendarEvent = nil
            self.pendingStop = nil
            self.onMeetingEnded?()
        }
        pendingStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Which running bundles count as native meeting apps, in priority order.
    /// Split out from `NSRunningApplication` so the choice is testable.
    static func meetingAppCandidates(bundleIDs: [(bundleID: String, pid: pid_t)]) -> [DetectedApp] {
        bundleIDs.compactMap { entry in
            guard let name = knownApps[entry.bundleID] else { return nil }
            return DetectedApp(name: name, bundleID: entry.bundleID, pid: entry.pid)
        }
    }

    /// A specific native app by bundle id, with no audio requirement at all —
    /// used to check whether a confirmation candidate is still open during a
    /// bridged gap, where the point is exactly that it may be silent right now.
    private static func nativeApp(bundleID: String,
                                  in running: [NSRunningApplication]) -> DetectedApp? {
        meetingAppCandidates(bundleIDs: running.compactMap { app in
            guard app.bundleIdentifier == bundleID else { return nil }
            return (bundleID: bundleID, pid: app.processIdentifier)
        }).first
    }

    private static func nativeMeetingApp(in running: [NSRunningApplication],
                                         requireAudio: Bool = false) -> DetectedApp? {
        let candidates = meetingAppCandidates(bundleIDs: running.compactMap { app in
            guard let bid = app.bundleIdentifier else { return nil }
            return (bundleID: bid, pid: app.processIdentifier)
        })
        guard requireAudio else { return candidates.first }
        let active = candidates.filter { hasAudio(for: $0) }
        guard !active.isEmpty else { return nil }
        if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let frontmost = active.first(where: { $0.pid == frontmostPID }) {
            return frontmost
        }
        return active.first
    }

    /// Web meetings by window title only (no calendar) — used by the audio
    /// monitor to confirm a browser tab is a meeting. The system-audio tap then
    /// captures the browser.
    static func visibleBrowserMeeting(in running: [NSRunningApplication] = NSWorkspace.shared.runningApplications) -> DetectedApp? {
        browserMeeting(in: running, calendarEvent: nil, calendarEnabled: false, requireCalendarForBrowser: false)
    }

    /// A browser that should be recorded as a meeting: window title matches a
    /// web-meeting marker, or — when calendar detection is on — an active event
    /// with a conferencing link is in progress and the browser is producing
    /// audio. The latter is what makes Google Meet reliable when Accessibility
    /// misses the title or the tab name is generic.
    private static func browserMeeting(in running: [NSRunningApplication],
                                       calendarEvent: CalendarMeetingCandidate?,
                                       calendarEnabled: Bool,
                                       requireCalendarForBrowser: Bool) -> DetectedApp? {
        let calendarBacked = calendarEnabled && calendarEvent?.meetingURL != nil
        for app in running {
            guard let bid = app.bundleIdentifier, browsers.contains(bid) else { continue }
            let titleMatches = ActivitySampler.focusedWindowTitle(pid: app.processIdentifier).map { title in
                webMeetingMarkers.contains { title.localizedCaseInsensitiveContains($0) }
            } ?? false
            // Skip the audio probe when no signal can apply.
            if requireCalendarForBrowser {
                guard calendarBacked else { continue }
            } else if !titleMatches && !calendarBacked {
                continue
            }
            let audioProcess = currentOutputAudioProcess(for: DetectedApp(
                name: app.localizedName ?? "Browser",
                bundleID: bid,
                pid: app.processIdentifier))
            guard MeetingMatcher.browserCountsAsMeeting(
                    titleMatchesMarker: titleMatches,
                    hasOutputAudio: audioProcess != nil,
                    calendarBacked: calendarBacked,
                    requireCalendarForBrowser: requireCalendarForBrowser)
            else { continue }
            return DetectedApp(name: app.localizedName ?? "Browser",
                               bundleID: bid,
                               pid: audioProcess?.id ?? app.processIdentifier)
        }
        return nil
    }

    static func hostBrowserBundleID(forAudioBundleID bundleID: String) -> String? {
        if browsers.contains(bundleID) { return bundleID }
        return browsers.first { browserAudioBundleID(bundleID, belongsTo: $0) }
    }

    static func browserAudioBundleID(_ bundleID: String, belongsTo browserBundleID: String) -> Bool {
        let bundle = bundleID.lowercased()
        let browser = browserBundleID.lowercased()
        return bundle == browser || bundle.hasPrefix("\(browser).helper")
    }

    /// Whether an audio process belongs to the detected meeting application's
    /// process family. Zoom routes call audio through `us.zoom.CptHost`, while
    /// Chromium-family browsers use `.helper` bundle identifiers.
    static func audioBundleID(_ bundleID: String, belongsTo appBundleID: String) -> Bool {
        if browsers.contains(appBundleID) {
            return browserAudioBundleID(bundleID, belongsTo: appBundleID)
        }
        let bundle = bundleID.lowercased()
        let host = appBundleID.lowercased()
        if host == "us.zoom.xos" {
            return bundle == host
                || bundle == "us.zoom.cpthost"
                || bundle.hasPrefix("us.zoom.xos.")
        }
        // Any bundle inside the host's own namespace is that app's audio.
        // Teams alone emits call audio from `<host>.helper` (WebView) *and*
        // `<host>.modulehost`, so matching only `.helper` misses the process
        // that is usually the one running. This mirrors the `us.zoom.xos.`
        // prefix rule above rather than enumerating every suffix Microsoft ships.
        return bundle == host || bundle.hasPrefix("\(host).")
    }

    /// Ranks an already-vetted set of output processes inside an app family.
    /// Detection supplies only processes that carry meeting signal; capture
    /// adds its broader open-stream and silent-process fallbacks separately.
    private static func rankedOutputAudioProcess(for app: DetectedApp,
                                                 in processes: [AudioProcess]) -> AudioProcess? {
        if browsers.contains(app.bundleID) || app.bundleID == "us.zoom.xos" {
            let matches = processes.filter { process in
                guard process.isRunningOutput, let bundleID = process.bundleID else { return false }
                return audioBundleID(bundleID, belongsTo: app.bundleID)
            }
            // Chrome/Edge/Safari often emit meeting audio from helper processes,
            // while the browser host can still expose a tap that only delivers
            // silence. Prefer a helper unless the detected PID is already one.
            return matches.first { $0.id == app.pid && $0.bundleID != app.bundleID }
                ?? matches.first { $0.bundleID != app.bundleID }
                ?? matches.first { $0.id == app.pid }
                ?? matches.first
        }
        // Electron meeting apps (Teams, Slack, Webex) route call audio through
        // helper processes just as Chromium browsers do. `audioBundleID` already
        // models that `<host>.helper` relationship for every host, so honour it
        // here as a fallback — without it `hasOutputAudio` stays false, the
        // detector never surfaces the app, and the process tap is skipped
        // entirely, leaving the meeting recorded mic-only. The host keeps
        // precedence so apps whose main process emits audio are unaffected.
        return processes.first {
            $0.id == app.pid && $0.isRunningOutput
        } ?? processes.first {
            $0.isRunningOutput && $0.bundleID == app.bundleID
        } ?? processes.first { process in
            guard process.isRunningOutput, let bundleID = process.bundleID else { return false }
            return audioBundleID(bundleID, belongsTo: app.bundleID)
        }
    }

    /// Best output process that is evidence of a live meeting. Detection-only:
    /// capture must use ``bestCaptureAudioProcess(for:in:)`` so bundles with
    /// always-open streams remain tappable.
    static func bestOutputAudioProcess(for app: DetectedApp,
                                       in processes: [AudioProcess]) -> AudioProcess? {
        rankedOutputAudioProcess(
            for: app,
            in: processes.filter { carriesMeetingSignal(bundleID: $0.bundleID) })
    }

    /// Canonical capture selection, including always-open streams plus the
    /// remembered and stable silent-process fallbacks. Keeping this entry point
    /// aligned with ``captureTargetProcess`` prevents detection-only ranking
    /// from leaking back into capture callers.
    static func bestCaptureAudioProcess(for app: DetectedApp,
                                        in processes: [AudioProcess]) -> AudioProcess? {
        captureTargetProcess(for: app, in: processes)
    }

    static func currentOutputAudioProcess(for app: DetectedApp) -> AudioProcess? {
        let processes = currentAudioProcesses()
        return bestOutputAudioProcess(for: app, in: processes)
    }

    /// The process to attach the capture tap to.
    ///
    /// Detection asks whether the app is producing output *right now*; capture
    /// only needs a process that *can* produce it — a tap on a momentarily
    /// silent process simply records nothing until audio starts. Falling back
    /// to the host PID is not an option: Teams' main process owns no Core Audio
    /// object at all, so `AudioHardwarePropertyTranslatePIDToProcessObject`
    /// fails and the tap is refused with `processNotFound` whenever the meeting
    /// happens to be quiet at the moment recording starts.
    static func captureTargetProcess(for app: DetectedApp,
                                     in processes: [AudioProcess],
                                     excludingPID: pid_t? = nil) -> AudioProcess? {
        let available = processes.filter { $0.id != excludingPID }
        let namespace = available.filter { process in
            guard let bundleID = process.bundleID else { return false }
            return audioBundleID(bundleID, belongsTo: app.bundleID)
        }
        // A process emitting right now is the answer, and worth remembering:
        // it is the only moment we learn which sibling of this app actually
        // carries call audio.
        if let emitting = bestOutputAudioProcess(for: app, in: available) {
            rememberCaptureTarget(emitting.id, for: app.bundleID)
            return emitting
        }
        // An always-open stream is intentionally excluded from meeting
        // detection, but it is preferable to a streamless helper for capture:
        // Core Audio will deliver silent buffers now and call audio later.
        if let openStream = namespace.filter(\.isRunningOutput).min(by: { $0.id < $1.id }) {
            rememberCaptureTarget(openStream.id, for: app.bundleID)
            return openStream
        }
        // Nothing is emitting. Core Audio specifies no order for the process
        // list, so picking the first sibling would tap a different one from
        // one call to the next — and with several Teams or browser helpers
        // alive, usually one that never carries call audio. Prefer the process
        // this app was last seen emitting from.
        if let remembered = rememberedCaptureTarget(for: app.bundleID),
           let process = namespace.first(where: { $0.id == remembered }) {
            return process
        }
        // Still nothing known: siblings before the host, for the same reason
        // the browser branch prefers helpers — the host is the process least
        // likely to own audio, and for Teams it owns no Core Audio object at
        // all. Lowest PID within each group so the choice is at least stable
        // across the retries the watchdog makes.
        let siblings = namespace.filter { $0.bundleID != app.bundleID }
        return siblings.min { $0.id < $1.id } ?? namespace.min { $0.id < $1.id }
    }

    /// The PID each app was last seen emitting from. Small and per-bundle: it
    /// only has to survive between a quiet start and the watchdog's next look.
    private static var lastEmittingCaptureTargets: [String: pid_t] = [:]

    private static func rememberCaptureTarget(_ pid: pid_t, for bundleID: String) {
        processSnapshotLock.lock()
        lastEmittingCaptureTargets[bundleID] = pid
        processSnapshotLock.unlock()
    }

    private static func rememberedCaptureTarget(for bundleID: String) -> pid_t? {
        processSnapshotLock.lock()
        defer { processSnapshotLock.unlock() }
        return lastEmittingCaptureTargets[bundleID]
    }

    /// Clears what capture learned about which sibling carries audio. For
    /// tests, so one case cannot leak its choice into the next.
    static func resetCaptureTargetMemory() {
        processSnapshotLock.lock()
        lastEmittingCaptureTargets.removeAll()
        processSnapshotLock.unlock()
    }

    /// A running native meeting app to capture from when nothing was detected.
    /// Deliberately does *not* require current output: a recording started by
    /// hand routinely begins before the remote side says anything, and a tap on
    /// a silent process records nothing until audio arrives rather than
    /// failing. Without this the manual path creates no system target at all,
    /// so remote speech arriving later cannot trigger watchdog recovery either.
    static func captureCandidateApp(
        in running: [NSRunningApplication] = NSWorkspace.shared.runningApplications
    ) -> DetectedApp? {
        nativeMeetingApp(in: running, requireAudio: false)
    }

    static func currentCaptureTargetProcess(
        for app: DetectedApp,
        excludingPID: pid_t? = nil
    ) -> AudioProcess? {
        captureTargetProcess(
            for: app,
            in: currentAudioProcesses(),
            excludingPID: excludingPID)
    }

    /// Compatibility entry point for callers that only need the default
    /// capture target. Recovery uses ``currentCaptureTargetProcess`` directly
    /// so it can exclude a dead attachment.
    static func currentCaptureAudioProcess(for app: DetectedApp) -> AudioProcess? {
        currentCaptureTargetProcess(for: app)
    }

    static func currentAudioProcesses(now: Date = Date()) -> [AudioProcess] {
        processSnapshotLock.lock()
        if let processSnapshot,
           now.timeIntervalSince(processSnapshot.capturedAt) <= processSnapshotLifetime {
            processSnapshotLock.unlock()
            return processSnapshot.processes
        }
        processSnapshotLock.unlock()

        let processes = (try? CoreAudioUtils.listAudioProcesses()) ?? []
        processSnapshotLock.lock()
        processSnapshot = (now, processes)
        processSnapshotLock.unlock()
        return processes
    }

    static func invalidateAudioProcessSnapshot() {
        processSnapshotLock.lock()
        processSnapshot = nil
        processSnapshotLock.unlock()
    }

    private static func continuingApp(_ app: DetectedApp, in running: [NSRunningApplication]) -> DetectedApp? {
        if knownApps[app.bundleID] != nil {
            return running.contains { $0.bundleIdentifier == app.bundleID } ? app : nil
        }
        if browsers.contains(app.bundleID) {
            return running.contains { $0.bundleIdentifier == app.bundleID } ? app : nil
        }
        return NSRunningApplication(processIdentifier: app.pid) == nil ? nil : app
    }

    private static func hasOutputAudio(for app: DetectedApp) -> Bool {
        currentOutputAudioProcess(for: app) != nil
    }

    /// The meeting app's own audio activity — output, or (native apps only)
    /// input. Used for the *continue* decision so it reflects the app rather
    /// than our recorder's hold on the default input device.
    private static func hasAudio(for app: DetectedApp) -> Bool {
        hasOutputAudio(for: app) || hasInputAudio(for: app)
    }

    private static func hasInputAudio(for app: DetectedApp) -> Bool {
        // Browser mic capture lives in helper processes we don't track here, so
        // browsers rely on output audio. For native apps the per-process input
        // flag is the app's own mic use — never our recorder's.
        guard !browsers.contains(app.bundleID) else { return false }
        return CoreAudioUtils.isProcessRunningInput(pid: app.pid)
    }
}
