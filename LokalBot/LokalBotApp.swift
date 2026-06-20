import SwiftUI
import Combine
import AVFoundation

@main
struct LokalBotV1App: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("LokalBotV1", id: "main") {
            MainWindowView()
                .environmentObject(app)
        }
        .defaultSize(width: 1180, height: 740)
        .commands {
            CommandMenu("Recording") {
                Button(app.isRecording ? "Stop Recording" : "Start Recording") {
                    app.isRecording
                        ? app.stopRecording()
                        : app.startRecording(detectedApp: app.detector.activeApp, source: "command")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Window("Welcome to LokalBotV1", id: "onboarding") {
            OnboardingView()
                .environmentObject(app)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(app)
        } label: {
            Image(systemName: app.isRecording ? "record.circle.fill" : "waveform.circle")
                .symbolRenderingMode(app.isRecording ? .multicolor : .monochrome)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(app)
        }
    }
}

/// Central app state + recording orchestration (the "coordinator" from the design doc §6).
@MainActor
final class AppState: ObservableObject {

    enum Status: Equatable {
        case idle
        case recording(meetingID: UUID)
    }

    enum NavSection: Hashable {
        case meetings, timeline, search, settings
    }

    /// True when launched by an XCUITest harness — gates the side-effectful
    /// startup paths (Core Audio polling, accessibility-trusted detector,
    /// Sparkle, periodic screenshots) so the UI renders against synthetic
    /// data without touching real audio, TCC, or the network. The env var
    /// is set by `LokalBotUITests` only; production launches never see it.
    static let isUITesting: Bool = ProcessInfo.processInfo.environment["LOKALBOTV1_UI_TEST"] == "1"

    @Published private(set) var status: Status = .idle
    @Published private(set) var meetings: [Meeting] = []
    @Published var lastError: String?
    @Published var settings = AppSettings.load() {
        didSet {
            settings.save()
            detector.stopDebounce = settings.stopDebounceSeconds
        }
    }

    // Navigation (main window): sidebar section, selected meeting, and a
    // pending "jump to timestamp" handed from search to the detail player.
    @Published var navSection: NavSection = .meetings
    @Published var selectedMeetingIDs: Set<Meeting.ID> = []
    @Published var pendingSeek: TimeInterval?

    /// The meeting shown in the detail pane (single selection only).
    var selectedMeeting: Meeting? {
        guard selectedMeetingIDs.count == 1, let id = selectedMeetingIDs.first else { return nil }
        return meetings.first { $0.id == id }
    }

    let storage = StorageManager()
    let detector = MeetingDetector()
    let audioMonitor = AudioSourceMonitor()
    private(set) lazy var searchIndex = SearchIndex(
        databaseURL: storage.rootURL.appendingPathComponent("lokalbotv1.sqlite"))
    private(set) lazy var activityStore = ActivityStore(
        databaseURL: storage.rootURL.appendingPathComponent("lokalbotv1.sqlite"))
    private(set) lazy var sampler = ActivitySampler(store: activityStore)
    private(set) lazy var embeddingIndex = EmbeddingIndex(
        databaseURL: storage.rootURL.appendingPathComponent("lokalbotv1.sqlite"),
        storage: storage)
    private(set) lazy var screenshots = ScreenshotService(
        store: activityStore, storage: storage, sampler: sampler) { [weak self] in
        self?.settings ?? AppSettings()
    }
    private(set) lazy var pipeline = ProcessingPipeline(storage: storage) { [weak self] in
        self?.settings ?? AppSettings()
    }

    private let micRecorder = MicRecorder()
    private let systemRecorder = SystemAudioRecorder()
    /// The live recording (shown at the top of the library while running).
    @Published private(set) var currentMeeting: Meeting?
    private var pipelineObserver: AnyCancellable?
    private var audioMonitorObserver: AnyCancellable?
    private var audioMonitorChangeForwarder: AnyCancellable?

    var isRecording: Bool { if case .recording = status { true } else { false } }
    var elapsed: TimeInterval {
        guard let m = currentMeeting else { return 0 }
        return Date().timeIntervalSince(m.startedAt)
    }

    init() {
        AppLog.bootstrap()
        meetings = storage.loadMeetings()
        // Views observe AppState only; forward pipeline / audio-monitor /
        // update-checker change notifications so MainWindowView refreshes
        // when those sub-ObservableObjects publish.
        pipelineObserver = pipeline.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        audioMonitorChangeForwarder = audioMonitor.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        pipeline.onArtifactsWritten = { [weak self] meeting in
            guard let self else { return }
            self.searchIndex.reindex(meeting, storage: self.storage)
            if self.settings.semanticSearchEnabled {
                Task { try? await self.embeddingIndex.index(meeting) }
            }
        }
        searchIndex.reindexAll(meetings, storage: storage)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            Task {
                await LlamaServer.shared.stop()
                await LlamaServer.embedder.stop()
            }
        }
        if handleHeadlessProcessing()
            || handleHeadlessSearch()
            || handleHeadlessRecord()
            || handleHeadlessShotTest()
            || handleHeadlessDigest() {
            return
        }
        // UI tests render against pre-seeded fixtures, not a real audio/Sparkle
        // session — bail out before any subsystem reaches for the mic, the
        // process list, or the network.
        if Self.isUITesting { return }
        applyTrackingSetting()
        detector.onMeetingStarted = { [weak self] app in
            guard let self else { return }
            switch self.settings.autoRecordMode {
            case .automatic: self.startRecording(detectedApp: app, source: "detector")
            case .ask: self.notifyMeetingDetected(app)
            case .manual: break
            }
        }
        detector.onMeetingEnded = { [weak self] in
            self?.stopRecording()
        }
        detector.stopDebounce = settings.stopDebounceSeconds
        systemRecorder.onCapturedProcessTerminated = { [weak self] in
            guard let self, self.isRecording else { return }
            self.lastError = "Meeting app exited — recording stopped."
            self.stopRecording()
        }
        // The mic-in-use signal misses meetings with a muted mic. The audio
        // monitor is the complementary "a meeting app just started producing
        // audio output" signal — in automatic mode it auto-records the
        // recognised meeting bundles; otherwise it surfaces a banner.
        audioMonitor.start()
        audioMonitorObserver = audioMonitor.$detectedProcess
            .compactMap { $0 }
            .sink { [weak self] process in self?.audioMonitorDetected(process) }
        detector.start()
        // Start Sparkle (silent background check). No-op on dev builds and
        // until the appcast feed URL + public key are configured (RELEASING.md).
        AppUpdateManager.shared.start()
    }

    // MARK: - Recording control

    /// Synchronous re-entrancy latch: `status` only flips inside the async
    /// start task, so without this, rapid triggers (detector ticks, double
    /// clicks) all pass the `!isRecording` guard and create empty meetings.
    private var isStartingRecording = false

    func startRecording(detectedApp: MeetingDetector.DetectedApp?, source: String = "ui") {
        guard !isRecording, !isStartingRecording else { return }
        isStartingRecording = true
        audioMonitor.isRecordingActive = true
        audioMonitor.accept()
        lokalbotv1Log("startRecording source=\(source) app=\(detectedApp?.name ?? "manual")")
        Task {
            defer { isStartingRecording = false }
            guard await MicRecorder.requestPermission() else {
                lastError = "Microphone permission denied."
                return
            }
            var created: Meeting?
            do {
                let title = detectedApp.map { "\($0.name) meeting" } ?? "Manual recording"
                var meeting = try storage.createMeetingFolder(title: title,
                                                              appName: detectedApp?.name ?? "Manual")
                created = meeting
                try micRecorder.start(writingTo: meeting.folderURL(in: storage).appendingPathComponent("mic.m4a"))

                if let pid = detectedApp?.pid {
                    do {
                        try systemRecorder.start(capturingPID: pid,
                                                 writingTo: meeting.folderURL(in: storage).appendingPathComponent("system.m4a"))
                        meeting.hasSystemTrack = true
                    } catch {
                        // Degrade gracefully: mic-only recording.
                        lastError = "System audio tap failed (\(error.localizedDescription)) — recording mic only."
                    }
                }
                currentMeeting = meeting
                status = .recording(meetingID: meeting.id)
            } catch {
                lastError = "Could not start recording: \(error.localizedDescription)"
                lokalbotv1Log("startRecording FAILED: \(error.localizedDescription)")
                // Don't leave a 0-minute husk in the library.
                if let husk = created { storage.deleteMeeting(husk) }
            }
        }
    }

    /// `AudioSourceMonitor` saw an app newly start producing output. Auto-record
    /// in automatic mode when the bundle is one we know how to record, fall
    /// back to the lastError banner otherwise so the user can choose.
    private func audioMonitorDetected(_ process: AudioProcess) {
        guard !isRecording, !isStartingRecording else { return }
        let isKnownMeetingApp = process.bundleID.map { MeetingDetector.knownApps[$0] != nil
            || MeetingDetector.browsers.contains($0) } ?? false
        guard isKnownMeetingApp, settings.autoRecordMode == .automatic else { return }
        let detected = MeetingDetector.DetectedApp(
            name: process.name, bundleID: process.bundleID ?? "", pid: process.id)
        startRecording(detectedApp: detected, source: "audio-monitor")
    }

    func stopRecording(process: Bool = true) {
        guard isRecording, var meeting = currentMeeting else { return }
        micRecorder.stop()
        systemRecorder.stop()
        audioMonitor.isRecordingActive = false
        audioMonitor.reseed()
        meeting.endedAt = Date()
        try? storage.saveMeta(meeting)
        meetings.insert(meeting, at: 0)
        currentMeeting = nil
        status = .idle
        if process && settings.autoTranscribe {
            pipeline.enqueue(meeting, transcribe: true, summarize: settings.autoSummarize)
        }
    }

    func reprocess(_ meeting: Meeting, transcribe: Bool, summarize: Bool) {
        pipeline.enqueue(meeting, transcribe: transcribe, summarize: summarize)
    }

    func applyTrackingSetting() {
        sampler.excludedApps = { [weak self] in self?.settings.excludedAppList ?? [] }
        settings.trackingEnabled ? sampler.start() : sampler.stop()
        screenshots.restart()
    }

    /// Search hit → open the meeting; transcript hits seek the player.
    func openSearchHit(_ hit: SearchIndex.Hit) {
        selectedMeetingIDs = [hit.meetingID]
        if hit.kind == .segment {
            pendingSeek = hit.start
        }
    }

    /// Permanently removes meetings: audio folder, list entry, both indexes.
    func deleteMeetings(_ ids: Set<Meeting.ID>) {
        for meeting in meetings where ids.contains(meeting.id) {
            storage.deleteMeeting(meeting)
            searchIndex.remove(meeting.id)
            embeddingIndex.remove(meeting.id)
        }
        meetings.removeAll { ids.contains($0.id) }
        selectedMeetingIDs.subtract(ids)
    }

    /// `LokalBotV1 --process <meeting folder>`: run the pipeline headless and
    /// exit. Lets the pipeline be exercised (and CI-tested) without the UI.
    private func handleHeadlessProcessing() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--process"), args.count > flag + 1 else { return false }
        let folder = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
              let decoded = try? decoder.decode(Meeting.self, from: data) else {
            print("LokalBotV1 --process: no readable meta.json in \(folder.path)")
            exit(2)
        }
        let summarize = !args.contains("--no-summary")
        pipeline.enqueue(decoded, transcribe: true, summarize: summarize)
        // Poll the pipeline until the job leaves the stage table, then exit.
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                switch pipeline.stages[decoded.id] {
                case .none:
                    print("LokalBotV1 --process: done → \(folder.path)")
                    await LlamaServer.shared.stop()
                    exit(0)
                case .failed(let message):
                    print("LokalBotV1 --process: FAILED — \(message)")
                    await LlamaServer.shared.stop()
                    exit(1)
                default:
                    continue
                }
            }
        }
        return true
    }

    /// `LokalBotV1 --record <seconds>`: manual mic recording, no pipeline.
    private func handleHeadlessRecord() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--record"), args.count > flag + 1,
              let seconds = Int(args[flag + 1]) else { return false }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("LokalBotV1 --record: SKIP (microphone not granted)")
            exit(3)
        }
        startRecording(detectedApp: nil, source: "headless")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard isRecording else {
                print("LokalBotV1 --record: FAILED to start — \(lastError ?? "no error recorded")")
                exit(1)
            }
            stopRecording(process: false)
            guard let meeting = meetings.first else { print("LokalBotV1 --record: no meeting"); exit(1) }
            print("LokalBotV1 --record: done → \(meeting.folderURL(in: storage).path)")
            exit(0)
        }
        return true
    }

    /// `LokalBotV1 --shot-test`: one screenshot capture, exit 0 ok / 3 skip / 1 fail.
    private func handleHeadlessShotTest() -> Bool {
        guard CommandLine.arguments.contains("--shot-test") else { return false }
        Task { @MainActor in
            guard CGPreflightScreenCaptureAccess() else {
                print("LokalBotV1 --shot-test: SKIP (screen recording not granted)")
                exit(3)
            }
            let before = Date()
            screenshots.captureNow()
            try? await Task.sleep(for: .seconds(8))
            if let shot = activityStore.screenshots(on: Date()).last(where: { $0.ts >= before }) {
                print("LokalBotV1 --shot-test: ok (app: \(shot.app))")
                exit(0)
            }
            print("LokalBotV1 --shot-test: FAILED (no screenshot row — see debug.log)")
            exit(1)
        }
        return true
    }

    /// `LokalBotV1 --digest today`: generate today's journal digest and exit.
    private func handleHeadlessDigest() -> Bool {
        guard CommandLine.arguments.contains("--digest") else { return false }
        Task { @MainActor in
            do {
                let day = Date()
                let todays = meetings.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }
                let (text, url) = try await pipeline.generateDayDigest(
                    for: day, blocks: activityStore.blocks(on: day),
                    meetings: todays, config: settings)
                print("LokalBotV1 --digest: \(url.path) (\(text.count) chars)")
                await LlamaServer.shared.stop()
                exit(0)
            } catch {
                print("LokalBotV1 --digest: FAILED — \(error.localizedDescription)")
                await LlamaServer.shared.stop()
                exit(1)
            }
        }
        return true
    }

    /// `LokalBotV1 --search <query>`: print index hits and exit. Test hook
    /// for the FTS5 index, same spirit as --process.
    private func handleHeadlessSearch() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--search"), args.count > flag + 1 else { return false }
        let query = args[flag + 1]
        let hits = searchIndex.search(query)
        print("LokalBotV1 --search: \(hits.count) keyword hit(s)")
        for hit in hits {
            let meeting = meetings.first { $0.id == hit.meetingID }
            print("[\(hit.kind.rawValue)] \(meeting?.title ?? hit.meetingID.uuidString) @ \(Transcript.stamp(hit.start)): \(hit.snippet)")
        }
        Task { @MainActor in
            if settings.semanticSearchEnabled {
                await embeddingIndex.reindexAll(meetings)
                let semantic = await embeddingIndex.search(query)
                print("LokalBotV1 --search: \(semantic.count) semantic hit(s)")
                for hit in semantic {
                    let meeting = meetings.first { $0.id == hit.meetingID }
                    print(String(format: "[≈%.2f] %@ @ %@: %@", hit.score,
                                 meeting?.title ?? "?", Transcript.stamp(hit.start),
                                 String(hit.text.prefix(90))))
                }
                await LlamaServer.embedder.stop()
                exit(hits.isEmpty && semantic.isEmpty ? 1 : 0)
            }
            exit(hits.isEmpty ? 1 : 0)
        }
        return true
    }

    private func notifyMeetingDetected(_ app: MeetingDetector.DetectedApp) {
        // M1: simple user notification via the menu bar (badge). A richer
        // UNUserNotification with a "Record" action button is a fast follow.
        lastError = nil
        NSSound.beep()
    }
}
