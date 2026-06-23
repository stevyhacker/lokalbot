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

    /// Browsers whose focused-window title we inspect for web meetings
    /// (needs Accessibility; silently skipped without it).
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox",
    ]
    private static let webMeetingMarkers = ["Meet – ", "Meet - ", "meet.google.com", "Jitsi", "Whereby"]

    var onMeetingStarted: ((DetectedApp) -> Void)?
    var onMeetingEnded: (() -> Void)?
    var stopDebounce: TimeInterval = 60

    private(set) var activeApp: DetectedApp?
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
        let running = NSWorkspace.shared.runningApplications
        let runningMeetingApp = Self.nativeMeetingApp(in: running)
            ?? Self.browserMeeting(in: running)
        let continuingApp = activeApp.flatMap { Self.continuingApp($0, in: running) }
        let app = runningMeetingApp ?? continuingApp
        let micInUse = Self.isMicInUse()
        let canStart = activeApp == nil && runningMeetingApp != nil && micInUse
        let canContinue = activeApp != nil && app != nil
            && (micInUse || Self.hasOutputAudio(for: app!))
        let inMeeting = canStart || canContinue

        if inMeeting, let app {
            pendingStop?.cancel()
            pendingStop = nil
            if activeApp == nil {
                activeApp = app
                onMeetingStarted?(app)
            } else {
                activeApp = app
            }
        } else if activeApp != nil, pendingStop == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.activeApp = nil
                self.pendingStop = nil
                self.onMeetingEnded?()
            }
            pendingStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + stopDebounce, execute: work)
        }
    }

    private static func nativeMeetingApp(in running: [NSRunningApplication]) -> DetectedApp? {
        running.compactMap { app -> DetectedApp? in
            guard let bid = app.bundleIdentifier, let name = knownApps[bid] else { return nil }
            return DetectedApp(name: name, bundleID: bid, pid: app.processIdentifier)
        }.first
    }

    /// Web meetings: a running browser whose focused window title looks like
    /// a meeting (design §9). The system-audio tap then captures the browser.
    static func visibleBrowserMeeting(in running: [NSRunningApplication] = NSWorkspace.shared.runningApplications) -> DetectedApp? {
        browserMeeting(in: running)
    }

    private static func browserMeeting(in running: [NSRunningApplication]) -> DetectedApp? {
        for app in running {
            guard let bid = app.bundleIdentifier, browsers.contains(bid),
                  let title = ActivitySampler.focusedWindowTitle(pid: app.processIdentifier),
                  webMeetingMarkers.contains(where: { title.localizedCaseInsensitiveContains($0) })
            else { continue }
            let audioProcess = bestBrowserAudioProcess(forBrowserBundleID: bid)
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

    // MARK: - Core Audio: is any process using the default input device?

    static func isMicInUse() -> Bool {
        CoreAudioUtils.isDefaultInputRunning()
    }
}
