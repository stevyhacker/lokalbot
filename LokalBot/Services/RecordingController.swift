import Foundation
import Combine

/// Owns the meeting-recording lifecycle: the two recorders (mic + system tap),
/// the start/stop state machine, the capture-health watchdog, the menu-bar
/// timer tick, and transcription-model prewarm. `AppState` keeps a reference,
/// republishes changes, and folds finished meetings into the library via
/// `onMeetingFinished`.
@MainActor
final class RecordingController: ObservableObject {

    enum Status: Equatable {
        case idle
        case recording(meetingID: UUID)
    }

    @Published private(set) var status: Status = .idle
    /// The live recording (shown at the top of the library while running).
    @Published private(set) var currentMeeting: Meeting?
    /// Drives `elapsed`; bumped each second by `recordingTick`.
    @Published private(set) var now = Date()

    private let storage: StorageManager
    private let settingsStore: SettingsStore
    private let audioMonitor: AudioSourceMonitor
    private let pipeline: ProcessingPipeline
    /// Surfaces user-facing problems (feeds `AppState.lastError`).
    private let onError: (String) -> Void
    /// A finished meeting leaves the controller here; the app inserts it into
    /// the library list.
    private let onMeetingFinished: (Meeting) -> Void
    /// Gates notifications + prewarm to the real interactive launch
    /// (not headless / UI tests).
    private let isInteractive: () -> Bool

    private let micRecorder = MicRecorder()
    private let systemRecorder = SystemAudioRecorder()

    private struct SystemAudioTarget {
        var bundleID: String
        var pid: pid_t
    }
    private var systemAudioTarget: SystemAudioTarget?
    private var recordingHealthWatchdog: AnyCancellable?
    private var lastMicRestartAt: Date?
    private var didWarnAboutMicCaptureStall = false
    private var lastSystemAudioReattachAt: Date?
    private var didWarnAboutSilentSystemAudio = false
    private var samePIDSystemAudioRetryCount = 0
    private static let recordingHealthWatchdogInterval: TimeInterval = 5
    private static let micCaptureInitialGrace: TimeInterval = 8
    private static let micCaptureStallGrace: TimeInterval = 15
    private static let micCaptureRestartCooldown: TimeInterval = 10
    private static let systemAudioInitialGrace: TimeInterval = 8
    private static let systemAudioSilentGrace: TimeInterval = 8
    private static let systemAudioReattachCooldown: TimeInterval = 10
    /// Calendar event id + stop time of the last calendar-backed recording, so
    /// the same scheduled meeting can't immediately re-record (helper-PID churn,
    /// brief audio drops). See `MeetingMatcher.shouldSuppressRepeat`.
    private var lastCalendarEventID: String?
    private var lastCalendarEventEndedAt: Date?
    private static let calendarRepeatCooldown: TimeInterval = 5 * 60

    /// Ticks once a second while recording so the menu bar timer (and popover)
    /// stay live even with no window open. Nil when idle.
    private var recordingTick: AnyCancellable?
    private var transcriptionPrewarmTask: Task<Void, Never>?

    /// Synchronous re-entrancy latch: `status` only flips inside the async
    /// start task, so without this, rapid triggers (detector ticks, double
    /// clicks) all pass the `!isRecording` guard and create empty meetings.
    private var isStartingRecording = false

    init(storage: StorageManager,
         settingsStore: SettingsStore,
         audioMonitor: AudioSourceMonitor,
         pipeline: ProcessingPipeline,
         isInteractive: @escaping () -> Bool,
         onError: @escaping (String) -> Void,
         onMeetingFinished: @escaping (Meeting) -> Void) {
        self.storage = storage
        self.settingsStore = settingsStore
        self.audioMonitor = audioMonitor
        self.pipeline = pipeline
        self.isInteractive = isInteractive
        self.onError = onError
        self.onMeetingFinished = onMeetingFinished
        systemRecorder.onCapturedProcessTerminated = { [weak self] in
            guard let self, self.isRecording else { return }
            self.onError("Meeting app exited — recording stopped.")
            self.stop()
        }
    }

    private var settings: AppSettings { settingsStore.current }

    var isRecording: Bool { if case .recording = status { true } else { false } }
    var isStarting: Bool { isStartingRecording }
    var elapsed: TimeInterval {
        guard let m = currentMeeting else { return 0 }
        return max(0, now.timeIntervalSince(m.startedAt))
    }

    /// Compact "MM:SS" (or "H:MM:SS") elapsed string for the menu bar label.
    var menuBarTimer: String {
        let total = Int(elapsed)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    func prepareForTermination() {
        transcriptionPrewarmTask?.cancel()
        transcriptionPrewarmTask = nil
        if isRecording { stop(process: false) }
    }

    // MARK: - Start / stop

    func start(context: MeetingDetectionContext? = nil, source: String = "ui") {
        guard !isRecording, !isStartingRecording else { return }
        let detectedApp = context?.detectedApp
        let calendarEvent = context?.calendarEvent
        // Don't immediately re-record the same scheduled event after one ended.
        if MeetingMatcher.shouldSuppressRepeat(
            eventID: calendarEvent?.externalID, lastEventID: lastCalendarEventID,
            lastEndedAt: lastCalendarEventEndedAt, now: Date(),
            cooldown: Self.calendarRepeatCooldown) {
            lokalbotLog("startRecording suppressed: calendar event \(calendarEvent?.externalID ?? "?") within cooldown")
            return
        }
        isStartingRecording = true
        audioMonitor.isRecordingActive = true
        audioMonitor.accept()
        lokalbotLog("startRecording source=\(source) app=\(detectedApp?.name ?? "manual") calendar=\(calendarEvent?.title ?? "none")")
        Task {
            defer { isStartingRecording = false }
            guard await MicRecorder.requestPermission() else {
                onError("Microphone permission denied.")
                audioMonitor.isRecordingActive = false
                audioMonitor.reseed()
                return
            }
            var created: Meeting?
            do {
                let title = MeetingMatcher.recordingTitle(
                    calendarTitle: calendarEvent?.title,
                    useCalendarTitles: settings.useCalendarTitles,
                    appName: detectedApp?.name)
                var meeting = try storage.createMeetingFolder(title: title,
                                                              appName: detectedApp?.name ?? "Manual")
                if let calendarEvent {
                    meeting.calendarProvider = calendarEvent.provider
                    meeting.calendarEventID = calendarEvent.externalID
                    meeting.calendarTitle = calendarEvent.title
                    meeting.scheduledStartAt = calendarEvent.startDate
                    meeting.scheduledEndAt = calendarEvent.endDate
                    meeting.meetingURL = calendarEvent.meetingURL
                    meeting.participantNameHints = calendarEvent.participantNames.isEmpty
                        ? nil
                        : calendarEvent.participantNames
                    try? storage.saveMeta(meeting)
                }
                created = meeting
                try micRecorder.start(
                    writingTo: meeting.folderURL(in: storage).appendingPathComponent("mic.m4a"),
                    previewTee: meeting.folderURL(in: storage)
                        .appendingPathComponent(AudioPreviewTee.micFileName))
                startRecordingHealthWatchdog()

                if let detectedApp {
                    let captureProcess = MeetingDetector.currentOutputAudioProcess(for: detectedApp)
                    let pid = captureProcess?.id ?? detectedApp.pid
                    do {
                        try systemRecorder.start(
                            capturingPID: pid,
                            writingTo: meeting.folderURL(in: storage).appendingPathComponent("system.m4a"),
                            previewTee: meeting.folderURL(in: storage)
                                .appendingPathComponent(AudioPreviewTee.systemFileName))
                        meeting.hasSystemTrack = true
                        systemAudioTarget = SystemAudioTarget(
                            bundleID: detectedApp.bundleID,
                            pid: pid)
                        if pid != detectedApp.pid || captureProcess?.bundleID != detectedApp.bundleID {
                            lokalbotLog(
                                "system audio capture resolved detectedPID=\(detectedApp.pid) capturePID=\(pid) captureBundle=\(captureProcess?.bundleID ?? "unknown") hostBundle=\(detectedApp.bundleID)")
                        }
                        lokalbotLog("system audio tap started pid=\(pid) bundle=\(detectedApp.bundleID)")
                    } catch {
                        // Degrade gracefully: mic-only recording.
                        onError("System audio tap failed (\(error.localizedDescription)) — recording mic only.")
                        lokalbotLog("system audio tap FAILED: \(error.localizedDescription)")
                    }
                }
                currentMeeting = meeting
                status = .recording(meetingID: meeting.id)
                startRecordingTick()
                if isInteractive() {
                    RecordingNotifier.shared.recordingStarted(title: meeting.title)
                    prewarmSelectedTranscriptionModel(reason: source)
                }
            } catch {
                onError("Could not start recording: \(error.localizedDescription)")
                lokalbotLog("startRecording FAILED: \(error.localizedDescription)")
                stopRecordingHealthWatchdog()
                systemAudioTarget = nil
                audioMonitor.isRecordingActive = false
                audioMonitor.reseed()
                // Don't leave a 0-minute husk in the library.
                if let husk = created { storage.deleteMeeting(husk) }
            }
        }
    }

    func stop(process: Bool = true) {
        guard isRecording, var meeting = currentMeeting else { return }
        stopRecordingHealthWatchdog()
        micRecorder.stop()
        systemRecorder.stop()
        systemAudioTarget = nil
        audioMonitor.isRecordingActive = false
        audioMonitor.reseed()
        stopRecordingTick()
        let endedAt = Date()
        meeting.endedAt = endedAt
        let folder = meeting.folderURL(in: storage)
        // The live-preview tees served their purpose; only the real tracks stay.
        for name in [AudioPreviewTee.micFileName, AudioPreviewTee.systemFileName] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        let micDuration = AudioFileInspector.duration(at: folder.appendingPathComponent("mic.m4a"))
        let systemDuration = AudioFileInspector.duration(at: folder.appendingPathComponent("system.m4a"))
        meeting.hasSystemTrack = AudioFileInspector.isTranscribableAudio(
            at: folder.appendingPathComponent("system.m4a"))
        // The wall-clock span can outlast the captured audio (e.g. a device
        // disruption truncates the tracks while the session stays live), so
        // store the actual playable length — the longest track — for the UI.
        meeting.recordedDuration = [micDuration, systemDuration].compactMap { $0 }.max()
        let wallDuration = endedAt.timeIntervalSince(meeting.startedAt)
        lokalbotLog(
            "recording stopped wall=\(String(format: "%.2fs", wallDuration)) recorded=\(String(format: "%.2fs", meeting.recordedDuration ?? 0)) mic=\(Self.formatAudioDuration(micDuration)) system=\(Self.formatAudioDuration(systemDuration)) hasSystem=\(meeting.hasSystemTrack)")
        if let recordedDuration = meeting.recordedDuration,
           wallDuration - recordedDuration > 60,
           recordedDuration < wallDuration * 0.8 {
            onError("Recording saved, but only \(meeting.durationLabel) of audio was captured from a \(Self.formatMinutes(wallDuration)) session.")
        }
        try? storage.saveMeta(meeting)
        lastCalendarEventID = meeting.calendarEventID
        lastCalendarEventEndedAt = endedAt
        currentMeeting = nil
        status = .idle
        onMeetingFinished(meeting)
        let willTranscribe = process && settings.autoTranscribe
        if isInteractive() {
            RecordingNotifier.shared.recordingStopped(
                title: meeting.title,
                duration: meeting.recordedDuration ?? endedAt.timeIntervalSince(meeting.startedAt),
                willTranscribe: willTranscribe)
        }
        if willTranscribe {
            pipeline.enqueue(meeting, transcribe: true, summarize: settings.autoSummarize)
        }
    }

    func splitForCalendarHandoff(_ context: MeetingDetectionContext) {
        guard isRecording, !isStartingRecording,
              let currentMeeting,
              let nextEventID = context.calendarEvent?.externalID,
              MeetingMatcher.shouldSplitForCalendarHandoff(
                  activeEventID: currentMeeting.calendarEventID,
                  nextEventID: nextEventID)
        else { return }
        lokalbotLog(
            "calendar handoff split old=\(currentMeeting.calendarEventID ?? "?") new=\(nextEventID)")
        stop()
        start(context: context, source: "calendar-handoff")
    }

    private func prewarmSelectedTranscriptionModel(reason: String) {
        guard settings.autoTranscribe else { return }
        guard transcriptionPrewarmTask == nil else { return }
        let choice = settings.transcriptionModel
        transcriptionPrewarmTask = Task { [weak self, choice, reason] in
            let started = Date()
            lokalbotLog("transcription prewarm start model=\(choice.rawValue) reason=\(reason)")
            do {
                try await choice.engine.prepare()
                let elapsed = Date().timeIntervalSince(started)
                lokalbotLog("transcription prewarm ready model=\(choice.rawValue) elapsed=\(String(format: "%.2fs", elapsed))")
            } catch {
                lokalbotLog("transcription prewarm FAILED model=\(choice.rawValue): \(error.localizedDescription)")
            }
            await MainActor.run { self?.transcriptionPrewarmTask = nil }
        }
    }

    /// Start/stop the once-a-second clock that keeps the menu bar timer live.
    private func startRecordingTick() {
        now = Date()
        recordingTick = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in self?.now = date }
    }

    private func stopRecordingTick() {
        recordingTick?.cancel()
        recordingTick = nil
    }

    // MARK: - Capture-health watchdog

    private func startRecordingHealthWatchdog() {
        stopRecordingHealthWatchdog()
        lastMicRestartAt = nil
        didWarnAboutMicCaptureStall = false
        lastSystemAudioReattachAt = nil
        didWarnAboutSilentSystemAudio = false
        samePIDSystemAudioRetryCount = 0
        recordingHealthWatchdog = Timer.publish(
            every: Self.recordingHealthWatchdogInterval,
            on: .main,
            in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkMicCapture()
                self?.checkSystemAudioCapture()
            }
    }

    private func stopRecordingHealthWatchdog() {
        recordingHealthWatchdog?.cancel()
        recordingHealthWatchdog = nil
        lastMicRestartAt = nil
        didWarnAboutMicCaptureStall = false
        lastSystemAudioReattachAt = nil
        didWarnAboutSilentSystemAudio = false
        samePIDSystemAudioRetryCount = 0
    }

    private func checkMicCapture() {
        guard isRecording, let meeting = currentMeeting else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(meeting.startedAt)
        guard elapsed >= Self.micCaptureInitialGrace else { return }

        let health = micRecorder.captureHealth()
        let captureLag = elapsed - health.duration
        guard captureLag >= Self.micCaptureStallGrace else { return }

        if let lastMicRestartAt,
           now.timeIntervalSince(lastMicRestartAt) < Self.micCaptureRestartCooldown {
            return
        }

        do {
            try micRecorder.restartCapture()
            lastMicRestartAt = now
            didWarnAboutMicCaptureStall = false
            lokalbotLog(
                "mic recorder restarted elapsed=\(String(format: "%.2fs", elapsed)) captured=\(String(format: "%.2fs", health.duration)) lag=\(String(format: "%.2fs", captureLag)) engineRunning=\(health.isEngineRunning)")
        } catch {
            lastMicRestartAt = now
            if !didWarnAboutMicCaptureStall {
                didWarnAboutMicCaptureStall = true
                onError("Microphone capture stalled (\(error.localizedDescription)); LokalBot is still trying to recover system audio.")
            }
            lokalbotLog(
                "mic recorder restart FAILED elapsed=\(String(format: "%.2fs", elapsed)) captured=\(String(format: "%.2fs", health.duration)) lag=\(String(format: "%.2fs", captureLag)): \(error.localizedDescription)")
        }
    }

    private func checkSystemAudioCapture() {
        guard isRecording, var target = systemAudioTarget, let meeting = currentMeeting else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(meeting.startedAt)
        guard elapsed >= Self.systemAudioInitialGrace else { return }

        let health = systemRecorder.captureHealth()
        let silentFor = health.lastAudibleWriteAt.map { now.timeIntervalSince($0) } ?? elapsed
        guard silentFor >= Self.systemAudioSilentGrace else { return }

        if let lastSystemAudioReattachAt,
           now.timeIntervalSince(lastSystemAudioReattachAt) < Self.systemAudioReattachCooldown {
            return
        }

        guard let candidate = currentSystemAudioCandidate(for: target) else {
            warnOnceAboutSilentSystemAudio(elapsed: elapsed, captured: health.duration,
                                           audible: health.audibleDuration,
                                           rms: health.lastRMSLevel,
                                           peakRMS: health.peakRMSLevel)
            return
        }

        // If the tap has never delivered audio, retry even on the same PID.
        // Once samples exist, reattach only when Core Audio reports a different
        // active process for the same meeting app/browser family.
        let shouldRetrySamePID = health.audibleDuration < AudioFileInspector.minimumTranscribableDuration
        let isSamePIDRetry = candidate.id == target.pid && shouldRetrySamePID
        guard candidate.id != target.pid || shouldRetrySamePID else {
            warnOnceAboutSilentSystemAudio(elapsed: elapsed, captured: health.duration,
                                           audible: health.audibleDuration,
                                           rms: health.lastRMSLevel,
                                           peakRMS: health.peakRMSLevel)
            return
        }
        guard !isSamePIDRetry || samePIDSystemAudioRetryCount < 2 else {
            warnOnceAboutSilentSystemAudio(elapsed: elapsed, captured: health.duration,
                                           audible: health.audibleDuration,
                                           rms: health.lastRMSLevel,
                                           peakRMS: health.peakRMSLevel)
            return
        }

        do {
            try systemRecorder.reattach(capturingPID: candidate.id)
            let previousPID = target.pid
            target.pid = candidate.id
            systemAudioTarget = target
            lastSystemAudioReattachAt = now
            samePIDSystemAudioRetryCount = isSamePIDRetry ? samePIDSystemAudioRetryCount + 1 : 0
            didWarnAboutSilentSystemAudio = false
            lokalbotLog(
                "system audio reattached oldPID=\(previousPID) newPID=\(candidate.id) bundle=\(candidate.bundleID ?? "unknown") captured=\(String(format: "%.2fs", health.duration)) audible=\(String(format: "%.2fs", health.audibleDuration)) silentFor=\(String(format: "%.2fs", silentFor)) rms=\(String(format: "%.6f", health.lastRMSLevel)) peakRMS=\(String(format: "%.6f", health.peakRMSLevel))")
        } catch {
            lastSystemAudioReattachAt = now
            onError("System audio capture was interrupted (\(error.localizedDescription)); still recording microphone.")
            lokalbotLog("system audio reattach FAILED: \(error.localizedDescription)")
        }
    }

    private func currentSystemAudioCandidate(for target: SystemAudioTarget) -> AudioProcess? {
        MeetingDetector.currentOutputAudioProcess(for: MeetingDetector.DetectedApp(
            name: target.bundleID,
            bundleID: target.bundleID,
            pid: target.pid))
    }

    private func warnOnceAboutSilentSystemAudio(elapsed: TimeInterval, captured: TimeInterval,
                                                audible: TimeInterval, rms: Float, peakRMS: Float) {
        guard !didWarnAboutSilentSystemAudio, elapsed >= 30 else { return }
        didWarnAboutSilentSystemAudio = true
        lokalbotLog(
            "system audio silent elapsed=\(String(format: "%.2fs", elapsed)) captured=\(String(format: "%.2fs", captured)) audible=\(String(format: "%.2fs", audible)) rms=\(String(format: "%.6f", rms)) peakRMS=\(String(format: "%.6f", peakRMS))")
        if audible < AudioFileInspector.minimumTranscribableDuration {
            onError("System audio capture is silent; LokalBot is keeping the microphone recording and will reattach if the meeting audio process changes.")
        }
    }

    private static func formatAudioDuration(_ duration: TimeInterval?) -> String {
        guard let duration else { return "missing" }
        return String(format: "%.2fs", duration)
    }

    private static func formatMinutes(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int(duration / 60))
        return "\(minutes) min"
    }
}
