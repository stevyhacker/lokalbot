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
    /// active calendar meeting backs the signal; otherwise the slower detector
    /// poll or the banner can handle them.
    private static let highConfidenceNativeAudioBundles: Set<String> = [
        "us.zoom.xos",
        "com.webex.meetingmanager",
        "Cisco-Systems.Spark",
    ]

    static func shouldAutoRecordNativeAudioMonitor(bundleID: String, calendarBacked: Bool) -> Bool {
        highConfidenceNativeAudioBundles.contains(bundleID) || calendarBacked
    }

    /// Browsers whose focused-window title we inspect for web meetings
    /// (needs Accessibility; silently skipped without it).
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox",
    ]
    private static let webMeetingMarkers = ["Meet – ", "Meet - ", "meet.google.com", "Jitsi", "Whereby"]

    var onMeetingStarted: ((MeetingDetectionContext) -> Void)?
    var onMeetingEnded: (() -> Void)?
    var stopDebounce: TimeInterval = 60
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

    private var micListener: AudioObjectPropertyListenerBlock?
    private var listenedDevice = AudioObjectID(kAudioObjectUnknown)
    /// Added once — re-adding on every re-arm multiplies Core Audio
    /// callbacks (each mic open/close then fans out into a tick storm).
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?

    func start() {
        // Safety-net poll (browser titles have no change notification).
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Instant signals: mic state, default-device change, app launch/quit.
        armMicListener()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.tick()
            }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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
        let runningMeetingApp = Self.nativeMeetingApp(in: running, requireAudio: true)
            ?? Self.browserMeeting(in: running, calendarEvent: calendarEvent,
                                   calendarEnabled: calendarEnabled,
                                   requireCalendarForBrowser: requireCalendarForBrowser)
        let continuingApp = activeApp.flatMap { Self.continuingApp($0, in: running) }
        let app = runningMeetingApp ?? continuingApp
        let isBrowserApp = runningMeetingApp.map { Self.browsers.contains($0.bundleID) } ?? false
        let calendarBackedBrowser = isBrowserApp && calendarEnabled && calendarEvent?.meetingURL != nil
        // Both start and continuation hinge on the selected app's OWN audio
        // (input or output), not the global mic flag. A global mic check can
        // belong to Dictation/QuickTime/another meeting app while a known meeting
        // app is merely idle in the background.
        let startAudioActive = runningMeetingApp.map { Self.hasAudio(for: $0) } ?? false
        let appAudioActive = app.map { Self.hasAudio(for: $0) } ?? false
        let calendarBackedBrowserWithAudio = calendarBackedBrowser
            && (runningMeetingApp.map { Self.hasOutputAudio(for: $0) } ?? false)
        let inMeeting = MeetingMatcher.isMeetingOngoing(
            hasActiveSession: activeApp != nil,
            hasRunningMeetingApp: runningMeetingApp != nil,
            hasContinuingApp: continuingApp != nil,
            startAudioActive: startAudioActive,
            appAudioActive: appAudioActive,
            calendarBackedBrowserWithAudio: calendarBackedBrowserWithAudio)

        if inMeeting, let app {
            pendingStop?.cancel()
            pendingStop = nil
            if activeApp == nil {
                activeApp = app
                activeCalendarEvent = calendarEvent
                onMeetingStarted?(MeetingDetectionContext(
                    detectedApp: app,
                    calendarEvent: calendarEvent,
                    confidence: MeetingMatcher.confidence(hasApp: true, hasCalendar: calendarEvent != nil),
                    reason: "detector"))
            } else {
                activeApp = app
                if let calendarEvent { activeCalendarEvent = calendarEvent }
            }
        } else if activeApp != nil, pendingStop == nil {
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
    }

    private static func nativeMeetingApp(in running: [NSRunningApplication],
                                         requireAudio: Bool = false) -> DetectedApp? {
        let candidates = running.compactMap { app -> DetectedApp? in
            guard let bid = app.bundleIdentifier, let name = knownApps[bid] else { return nil }
            return DetectedApp(name: name, bundleID: bid, pid: app.processIdentifier)
        }
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
            let audioProcess = bestBrowserAudioProcess(forBrowserBundleID: bid)
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

    private static func bestBrowserAudioProcess(forBrowserBundleID browserBundleID: String) -> AudioProcess? {
        let processes = (try? CoreAudioUtils.listAudioProcesses()) ?? []
        return processes.first { process in
            guard process.isRunningOutput, let bundleID = process.bundleID else { return false }
            return browserAudioBundleID(bundleID, belongsTo: browserBundleID)
        }
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
        if browsers.contains(app.bundleID) {
            return bestBrowserAudioProcess(forBrowserBundleID: app.bundleID) != nil
        }
        return CoreAudioUtils.isProcessRunningOutput(pid: app.pid)
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

    // MARK: - Core Audio: is any process using the default input device?

    static func isMicInUse() -> Bool {
        CoreAudioUtils.isDefaultInputRunning()
    }
}
