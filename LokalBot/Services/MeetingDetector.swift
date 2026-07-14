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
        return bundle == host || bundle.hasPrefix("\(host).helper")
    }

    static func bestOutputAudioProcess(for app: DetectedApp,
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
        return processes.first { $0.id == app.pid && $0.isRunningOutput }
            ?? processes.first { $0.isRunningOutput && $0.bundleID == app.bundleID }
    }

    static func currentOutputAudioProcess(for app: DetectedApp) -> AudioProcess? {
        let processes = currentAudioProcesses()
        return bestOutputAudioProcess(for: app, in: processes)
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

    // MARK: - Core Audio: is any process using the default input device?

    static func isMicInUse() -> Bool {
        CoreAudioUtils.isDefaultInputRunning()
    }
}
