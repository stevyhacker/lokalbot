import SwiftUI
import Combine
import AVFoundation

@main
struct LokalBotApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("LokalBot", id: "main") {
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

        Window("Welcome to LokalBot", id: "onboarding") {
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

    @Published private(set) var status: Status = .idle
    @Published private(set) var meetings: [Meeting] = []
    @Published var lastError: String?
    @Published var settings = AppSettings.load() {
        didSet { settings.save() }
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
    private(set) lazy var searchIndex = SearchIndex(
        databaseURL: storage.rootURL.appendingPathComponent("lokalbot.sqlite"))
    private(set) lazy var activityStore = ActivityStore(
        databaseURL: storage.rootURL.appendingPathComponent("lokalbot.sqlite"))
    private(set) lazy var sampler = ActivitySampler(store: activityStore)
    private(set) lazy var embeddingIndex = EmbeddingIndex(
        databaseURL: storage.rootURL.appendingPathComponent("lokalbot.sqlite"),
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

    var isRecording: Bool { if case .recording = status { true } else { false } }
    var elapsed: TimeInterval {
        guard let m = currentMeeting else { return 0 }
        return Date().timeIntervalSince(m.startedAt)
    }

    init() {
        meetings = storage.loadMeetings()
        // Views observe AppState only; forward pipeline stage changes so
        // detail views refresh as transcripts/summaries land on disk.
        pipelineObserver = pipeline.objectWillChange.sink { [weak self] in
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
        detector.start()
    }

    // MARK: - Recording control

    /// Synchronous re-entrancy latch: `status` only flips inside the async
    /// start task, so without this, rapid triggers (detector ticks, double
    /// clicks) all pass the `!isRecording` guard and create empty meetings.
    private var isStartingRecording = false

    func startRecording(detectedApp: MeetingDetector.DetectedApp?, source: String = "ui") {
        guard !isRecording, !isStartingRecording else { return }
        isStartingRecording = true
        lokalbotLog("startRecording source=\(source) app=\(detectedApp?.name ?? "manual")")
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
                lokalbotLog("startRecording FAILED: \(error.localizedDescription)")
                // Don't leave a 0-minute husk in the library.
                if let husk = created { storage.deleteMeeting(husk) }
            }
        }
    }

    func stopRecording(process: Bool = true) {
        guard isRecording, var meeting = currentMeeting else { return }
        micRecorder.stop()
        systemRecorder.stop()
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

    /// `LokalBot --process <meeting folder>`: run the pipeline headless and
    /// exit. Lets the pipeline be exercised (and CI-tested) without the UI.
    private func handleHeadlessProcessing() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--process"), args.count > flag + 1 else { return false }
        let folder = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
              let decoded = try? decoder.decode(Meeting.self, from: data) else {
            print("LokalBot --process: no readable meta.json in \(folder.path)")
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
                    print("LokalBot --process: done → \(folder.path)")
                    await LlamaServer.shared.stop()
                    exit(0)
                case .failed(let message):
                    print("LokalBot --process: FAILED — \(message)")
                    await LlamaServer.shared.stop()
                    exit(1)
                default:
                    continue
                }
            }
        }
        return true
    }

    /// `LokalBot --record <seconds>`: manual mic recording, no pipeline.
    private func handleHeadlessRecord() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--record"), args.count > flag + 1,
              let seconds = Int(args[flag + 1]) else { return false }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("LokalBot --record: SKIP (microphone not granted)")
            exit(3)
        }
        startRecording(detectedApp: nil, source: "headless")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard isRecording else {
                print("LokalBot --record: FAILED to start — \(lastError ?? "no error recorded")")
                exit(1)
            }
            stopRecording(process: false)
            guard let meeting = meetings.first else { print("LokalBot --record: no meeting"); exit(1) }
            print("LokalBot --record: done → \(meeting.folderURL(in: storage).path)")
            exit(0)
        }
        return true
    }

    /// `LokalBot --shot-test`: one screenshot capture, exit 0 ok / 3 skip / 1 fail.
    private func handleHeadlessShotTest() -> Bool {
        guard CommandLine.arguments.contains("--shot-test") else { return false }
        Task { @MainActor in
            guard CGPreflightScreenCaptureAccess() else {
                print("LokalBot --shot-test: SKIP (screen recording not granted)")
                exit(3)
            }
            let before = Date()
            screenshots.captureNow()
            try? await Task.sleep(for: .seconds(8))
            if let shot = activityStore.screenshots(on: Date()).last(where: { $0.ts >= before }) {
                print("LokalBot --shot-test: ok (app: \(shot.app))")
                exit(0)
            }
            print("LokalBot --shot-test: FAILED (no screenshot row — see debug.log)")
            exit(1)
        }
        return true
    }

    /// `LokalBot --digest today`: generate today's journal digest and exit.
    private func handleHeadlessDigest() -> Bool {
        guard CommandLine.arguments.contains("--digest") else { return false }
        Task { @MainActor in
            do {
                let day = Date()
                let todays = meetings.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }
                let (text, url) = try await pipeline.generateDayDigest(
                    for: day, blocks: activityStore.blocks(on: day),
                    meetings: todays, config: settings)
                print("LokalBot --digest: \(url.path) (\(text.count) chars)")
                await LlamaServer.shared.stop()
                exit(0)
            } catch {
                print("LokalBot --digest: FAILED — \(error.localizedDescription)")
                await LlamaServer.shared.stop()
                exit(1)
            }
        }
        return true
    }

    /// `LokalBot --search <query>`: print index hits and exit. Test hook
    /// for the FTS5 index, same spirit as --process.
    private func handleHeadlessSearch() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--search"), args.count > flag + 1 else { return false }
        let query = args[flag + 1]
        let hits = searchIndex.search(query)
        print("LokalBot --search: \(hits.count) keyword hit(s)")
        for hit in hits {
            let meeting = meetings.first { $0.id == hit.meetingID }
            print("[\(hit.kind.rawValue)] \(meeting?.title ?? hit.meetingID.uuidString) @ \(Transcript.stamp(hit.start)): \(hit.snippet)")
        }
        Task { @MainActor in
            if settings.semanticSearchEnabled {
                await embeddingIndex.reindexAll(meetings)
                let semantic = await embeddingIndex.search(query)
                print("LokalBot --search: \(semantic.count) semantic hit(s)")
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
