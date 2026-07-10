import SwiftUI
import Combine
import AVFoundation

/// Process entry point. Parses any headless subcommand before SwiftUI exists,
/// and disables AppKit window restoration *before* SwiftUI launches when
/// starting menu-bar-only — `applicationWillFinishLaunching` runs after AppKit
/// has already read the flag, so a previously-open window would be restored
/// and force the Dock icon back on. Setting it pre-launch is the only
/// reliable point.
@main
enum LokalBotMain {
    @MainActor
    static func main() {
        // Carry a prior LokalBotV2 install's data forward before anything reads
        // a store: settings are loaded below (via lokalbotLaunchesMenuBarOnly),
        // and AppState builds StorageManager/SearchIndex right after.
        DataMigration.runIfNeeded()
        HeadlessCommand.requested = HeadlessCommand.parse(CommandLine.arguments)
        UserDefaults.standard.set(lokalbotLaunchesMenuBarOnly(),
                                  forKey: "ApplePersistenceIgnoreState")
        LokalBotApp.main()
    }
}

struct LokalBotApp: App {
    @StateObject private var app: AppState
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let appState = AppState()
        _app = StateObject(wrappedValue: appState)
        AppDelegate.appState = appState
    }

    var body: some Scene {
        Window("LokalBot", id: "main") {
            mainWindow
        }
        .defaultSize(width: 1180, height: 740)
        .commands {
            CommandMenu("Recording") {
                Button(app.isRecording ? "Stop Recording" : "Start Recording") {
                    app.isRecording
                        ? app.stopRecording()
                        : app.startRecording(context: app.recordingContext(for: app.detector.activeApp), source: "command")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button(app.dictation.state.isRecording ? "Stop Dictation" : "Start Dictation") {
                    app.dictation.toggle(source: "command")
                }
            }
            // ⌘K opens the command palette. Registered at the app level so it
            // works from anywhere; the palette window is opened via openWindow.
            CommandGroup(after: .toolbar) {
                Button("Command Palette…") {
                    WindowAccess.shared.open("palette")
                }
                .keyboardShortcut("k", modifiers: [.command])
            }
        }

        Window("Welcome to LokalBot", id: "onboarding") {
            OnboardingView()
                .environmentObject(app)
        }
        .windowResizability(.contentSize)

        // The ⌘K command palette. A lightweight, keyboard-first launcher that
        // records, navigates, and opens recent meetings without the sidebar.
        Window("Command Palette", id: "palette") {
            CommandPaletteView()
                .environmentObject(app)
                .brandTinted()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

#if !LOKALBOT_UI_TEST_HOST
        MenuBarExtra {
            MenuBarView()
                .environmentObject(app)
                .brandTinted()
        } label: {
            MenuBarLabel(app: app)
        }
        .menuBarExtraStyle(.window)
#endif

        Settings {
            SettingsView()
                .environmentObject(app)
                .brandTinted()
        }
    }

    private var mainWindow: some View {
        MainWindowView()
            .environmentObject(app)
            .brandTinted()
    }
}

/// Central app state (the "coordinator" from the design doc §6): dependency
/// wiring, the meeting library, navigation, and the detection→recording glue.
/// The recording lifecycle itself lives in `RecordingController`; headless
/// subcommands in `HeadlessCommandRunner`; AppKit launch plumbing in
/// `AppLifecycle.swift`.
@MainActor
final class AppState: ObservableObject {

    enum NavSection: Hashable {
        case timeline, meetings, type, ask, agent, settings

        /// Section names accepted from the UI-test capture environment and
        /// deep links. Legacy names keep working: "capture" (the pre-split
        /// merged section) lands on Timeline, "dictation" and "cotyping" on
        /// Type, "search"/"chat" on Ask (spec §2.1), and "models" on
        /// Settings, which absorbed it as a tab (spec §2.5).
        init?(captureName: String) {
            switch captureName.lowercased() {
            case "timeline", "capture": self = .timeline
            case "meetings": self = .meetings
            case "type", "dictation", "cotyping": self = .type
            case "ask", "search", "chat": self = .ask
            case "agent": self = .agent
            case "settings", "models": self = .settings
            default: return nil
            }
        }
    }

    /// Which tool the Type section shows. Session-sticky: preserved while
    /// navigating away so returning lands on the last-used tab.
    enum TypeTab: String, CaseIterable {
        case dictation, cotyping

        /// Legacy capture names select their tab; anything else leaves the
        /// current tab untouched.
        init?(captureName: String) {
            switch captureName.lowercased() {
            case "dictation": self = .dictation
            case "cotyping": self = .cotyping
            default: return nil
            }
        }
    }

    /// Which tab the Settings surface shows (spec §2.5 — Settings absorbs
    /// Models as a tab strip). Session-sticky like TypeTab.
    enum SettingsTab: String, CaseIterable {
        case general, recording, models, privacy, advanced

        var displayName: String { rawValue.capitalized }

        /// Legacy capture names select their tab; the pre-merge "models"
        /// section name lands on the Models tab.
        init?(captureName: String) {
            switch captureName.lowercased() {
            case "general": self = .general
            case "recording": self = .recording
            case "models": self = .models
            case "privacy": self = .privacy
            case "advanced": self = .advanced
            default: return nil
            }
        }
    }

    /// True when launched by an XCUITest harness — gates the side-effectful
    /// startup paths (Core Audio polling, accessibility-trusted detector,
    /// Sparkle, periodic screenshots) so the UI renders against synthetic
    /// data without touching real audio, TCC, or the network.
    nonisolated static var isUITesting: Bool { UITestRuntime.isEnabled }

    /// UserDefaults flag: the permission onboarding has been shown once. Also
    /// read by `AppDelegate` to keep the first run windowed.
    nonisolated static let onboardingShownKey = "lokalbotv3.onboarding.shown"

    @Published private(set) var meetings: [Meeting] = []
    @Published var lastError: String?

    /// The always-alive settings owner; services capture this, never AppState.
    let settingsStore = SettingsStore()

    /// UI-facing settings surface (views bind `$app.settings.x`). Writes flow
    /// through to `settingsStore` (which persists) and fan out to the
    /// subsystems that apply settings live.
    @Published var settings: AppSettings {
        didSet {
            settingsStore.current = settings
            detector.stopDebounce = settings.stopDebounceSeconds
            detector.calendarEnabled = settings.calendarDetectionEnabled
            detector.requireCalendarForBrowser = settings.requireCalendarForBrowser
            if interactive {
                dictation.applySettings()
                cotyping.applySettings()
                if settings.cotypingEnabled { Task { await cotypingEngine.prewarm() } }
            }
        }
    }

    // Navigation (main window): sidebar section, selected meeting, and a
    // pending "jump to timestamp" handed from search to the detail player.
    @Published var navSection: NavSection = .timeline
    @Published var typeTab: TypeTab = .dictation
    @Published var settingsTab: SettingsTab = .general
    @Published var selectedMeetingIDs: Set<Meeting.ID> = []
    @Published var pendingSeek: TimeInterval?

    /// A query handed to the Ask section by another surface (⌘K palette).
    /// AskView consumes and clears it on appear/change.
    @Published var askPrefill: String?

    /// A day handed to the Ask section (the old Timeline "Ask" tab, spec
    /// §2.2): rendered as a removable chip, and prepended to escalated
    /// queries so the assistant scopes its answer to that day.
    @Published var askDayScope: Date?

    /// Navigate to the Type section with a specific tab preselected.
    func openType(_ tab: TypeTab) {
        typeTab = tab
        navSection = .type
    }

    /// Navigate to Settings with a specific tab preselected.
    func openSettings(tab: SettingsTab) {
        settingsTab = tab
        navSection = .settings
    }

    /// Navigate to the Ask section, optionally pre-filling the query and/or
    /// scoping it to a day (Timeline's "Ask about this day").
    func openAsk(query: String = "", dayScope: Date? = nil) {
        askPrefill = query.isEmpty ? nil : query
        askDayScope = dayScope
        navSection = .ask
    }

    /// Open one meeting in the Meetings section — the deep-link target
    /// for search hits, menu-bar recents, and palette recents.
    func openMeeting(_ id: Meeting.ID) {
        selectedMeetingIDs = [id]
        navSection = .meetings
    }

    /// The meeting shown in the detail pane (single selection only). The
    /// in-progress recording is a first-class citizen here: selecting its
    /// row resolves to `currentMeeting`, which `CaptureDetailView` routes
    /// to the live view.
    var selectedMeeting: Meeting? {
        guard selectedMeetingIDs.count == 1, let id = selectedMeetingIDs.first else { return nil }
        if let live = currentMeeting, live.id == id { return live }
        return meetings.first { $0.id == id }
    }

    let storage = StorageManager()
    private(set) lazy var cotypingLearning = CotypingLearningStore(storageRoot: storage.rootURL)
    let detector = MeetingDetector()
    let audioMonitor = AudioSourceMonitor()
    /// Read-only calendar access (EventKit): confirms meetings and titles
    /// recordings. Concrete type so the settings UI observes its permission
    /// state; handed to the detector as the `CalendarEventProviding` seam.
    let calendar = EventKitCalendarEventProvider()
    private(set) lazy var searchIndex = SearchIndex(
        databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"))
    private(set) lazy var activityStore = ActivityStore(
        databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"))
    private(set) lazy var sampler = ActivitySampler(store: activityStore)
    private(set) lazy var embeddingIndex = EmbeddingIndex(
        databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"),
        storage: storage)
    private(set) lazy var screenshots = ScreenshotService(
        store: activityStore, storage: storage, sampler: sampler,
        isMeetingRecordingActive: { [weak self] in
            guard let self else { return false }
            return self.recording.isRecording || self.recording.isStarting
        }) { [store = settingsStore] in
        store.current
    }
    private(set) lazy var pipelineJobStore = PipelineJobStore(
        databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"))
    private(set) lazy var pipeline = ProcessingPipeline(
        storage: storage, jobStore: pipelineJobStore) { [store = settingsStore] in
        store.current
    }
    /// Meeting-recording lifecycle: recorders, watchdog, timer tick, prewarm.
    private(set) lazy var recording = RecordingController(
        storage: storage,
        settingsStore: settingsStore,
        audioMonitor: audioMonitor,
        pipeline: pipeline,
        isInteractive: { [weak self] in self?.interactive ?? false },
        onError: { [weak self] message in self?.lastError = message },
        onMeetingFinished: { [weak self] meeting in self?.meetings.insert(meeting, at: 0) })
    /// Handy-style press-and-speak dictation. It records mic-only audio, uses
    /// the selected local transcription model, then inserts the transcript into
    /// the focused app using the same clipboard-safe path as cotyping.
    private(set) lazy var dictation = DictationCoordinator(
        storageRoot: storage.rootURL,
        settingsProvider: { [store = settingsStore] in store.current },
        canStart: { [weak self] in !(self?.isRecording ?? false) },
        onBusy: { [weak self] in
            self?.lastError = "Stop the current meeting recording before starting dictation."
        },
        onError: { [weak self] message in
            self?.lastError = message
        })
    /// Cotyping (inline AI autocomplete). Always runs its own model on the
    /// dedicated `LlamaServer.cotyping` instance so it never thrashes the
    /// shared summarizer server. Resolved per-completion, so changes apply live.
    private(set) lazy var cotypingEngine = CotypingEngineSelector(
        http: CotypingEngine(makeEngine: { [weak self] in
            guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
            return try await self.pipeline.makeTextEngine(
                self.settings.cotypingTextEngineSettings,
                server: .cotyping)
        }),
        makeLocal: { modelPath in
            LocalLlamaCotypingEngine(runtime: LlamaCotypingRuntime(), modelPath: modelPath)
        },
        settings: { [store = settingsStore] in store.current },
        storage: storage)
    private(set) lazy var cotyping = CotypingCoordinator(
        engine: cotypingEngine,
        settingsProvider: { [store = settingsStore] in store.current },
        learningStore: cotypingLearning,
        isMeetingRecordingActive: { [weak self] in
            guard let self else { return false }
            return self.recording.isRecording || self.recording.isStarting
        })
    /// Rolling live transcript of the recording in progress (preview only —
    /// the pipeline's post-meeting transcript stays authoritative).
    private(set) lazy var liveTranscriber = LiveMeetingTranscriber(
        storageRoot: storage.rootURL,
        settings: { [store = settingsStore] in store.current })

    @MainActor
    func prepareRecommendedCotypingModel() {
        CotypingModelPreparer.prepareRecommended(
            settings: &settings,
            storage: storage,
            downloads: ModelDownloadManager.shared)
    }

    /// Chat assistant (the "Chat" section). Reuses the summariser's `TextEngine`
    /// and a tool-calling agent over the live meeting list + search indexes.
    private(set) lazy var chat = ChatViewModel(
        makeEngine: { [weak self] in
            guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
            return try await self.pipeline.makeTextEngine(self.settings)
        },
        tools: MeetingChatTools(
            meetings: { [weak self] in self?.meetings ?? [] },
            storage: storage,
            searchIndex: searchIndex,
            embeddingIndex: embeddingIndex,
            activityStore: activityStore,
            settings: { [store = settingsStore] in store.current }),
        store: ChatStore(rootURL: storage.rootURL))

    // Agent Mode (pi). Installer and tab manager are cheap; each tab lazily
    // spawns its own controller/process when AgentView mounts it.
    let agentInstaller = AgentRuntimeInstaller()
    private(set) lazy var agentSessions = AgentSessionTabs(
        settings: { [store = settingsStore] in store.current },
        storage: storage)
    var agentController: AgentSessionController {
        agentSessions.ensureSelectedController()
    }

    private var pipelineObserver: AnyCancellable?
    private var recordingObserver: AnyCancellable?
    private var recordingStatusObserver: AnyCancellable?
    private var audioMonitorObserver: AnyCancellable?
    private var audioMonitorChangeForwarder: AnyCancellable?
    private var calendarObserver: AnyCancellable?
    /// True only on the real interactive launch path (not headless / UI test) —
    /// gates recording notifications and first-run onboarding.
    private var interactive = false
    private var terminationCleanupTask: Task<Void, Never>?

    // Recording facades — views observe AppState only.
    var isRecording: Bool { recording.isRecording }
    var currentMeeting: Meeting? { recording.currentMeeting }
    var elapsed: TimeInterval { recording.elapsed }
    var menuBarTimer: String { recording.menuBarTimer }

    func startRecording(context: MeetingDetectionContext? = nil, source: String = "ui") {
        recording.start(context: context, source: source)
    }

    func stopRecording(process: Bool = true) {
        recording.stop(process: process)
    }

    /// Recording started, stopped, or split to a new meeting: quiet cotyping
    /// and (re)point the live transcriber at the active meeting folder.
    private func meetingRecordingStateDidChange(active: Bool) {
        guard interactive else { return }
        if settings.cotypingEnabled {
            cotyping.meetingRecordingStateChanged(active: active)
        }
        if active, let meeting = recording.currentMeeting {
            liveTranscriber.prepare(folder: meeting.folderURL(in: storage))
        } else {
            liveTranscriber.stop()
        }
    }

    /// Menu-bar path to the live meeting: land on the library with the
    /// in-progress recording selected, so the detail pane shows the live
    /// transcript and notes.
    func showLiveMeeting() {
        guard let live = currentMeeting else { return }
        navSection = .meetings
        selectedMeetingIDs = [live.id]
        WindowAccess.shared.open("main")
    }

    init() {
        AppLog.bootstrap()
        settings = settingsStore.current
        var loaded = storage.loadMeetings()
        // One-time backfill: meetings recorded before `recordedDuration` existed
        // would otherwise show the wall-clock span (which can exceed the captured
        // audio). Measure the actual playable length once and persist it.
        for i in loaded.indices where loaded[i].recordedDuration == nil && loaded[i].endedAt != nil {
            let folder = loaded[i].folderURL(in: storage)
            if let recorded = ["mic.m4a", "system.m4a"]
                .compactMap({ AudioFileInspector.duration(at: folder.appendingPathComponent($0)) })
                .max() {
                loaded[i].recordedDuration = recorded
                try? storage.saveMeta(loaded[i])
            }
        }
        meetings = loaded
        LiveMeetingTranscriber.sweepOrphanedSnapshots(storageRoot: storage.rootURL)
        // Views observe AppState only; forward pipeline / recording /
        // audio-monitor / calendar change notifications so MainWindowView
        // refreshes when those sub-ObservableObjects publish.
        pipelineObserver = pipeline.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        // Forward lifecycle changes, but not RecordingController's one-second
        // `now` tick. Timer labels observe the controller directly; rebroadcasting
        // that tick through AppState invalidated the entire window hierarchy.
        recordingObserver = Publishers.CombineLatest(
            recording.$status,
            recording.$currentMeeting
        ).dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // React to recording start/stop (and calendar-handoff splits, which
        // change the meeting ID mid-recording): pause cotyping and run the
        // live transcriber against the active meeting folder.
        recordingStatusObserver = recording.$status
            .map { status -> UUID? in
                if case .recording(let meetingID) = status { return meetingID }
                return nil
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] meetingID in
                self?.meetingRecordingStateDidChange(active: meetingID != nil)
            }
        audioMonitorChangeForwarder = audioMonitor.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        calendarObserver = calendar.objectWillChange.sink { [weak self] in
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
        if let command = HeadlessCommand.requested {
            HeadlessCommandRunner(app: self).run(command)
            return
        }
        // UI tests render against pre-seeded fixtures, not a real audio/Sparkle
        // session — bail out before any subsystem reaches for the mic, the
        // process list, or the network.
        if Self.isUITesting { return }
        interactive = true
        RecordingNotifier.shared.bootstrap()
        applyTrackingSetting()
        // Crash recovery: re-enqueue any meeting whose processing never
        // finished — a quit or crash mid-transcription used to lose the job.
        pipeline.resumePending(meetings: meetings)
        detector.onMeetingStarted = { [weak self] context in
            guard let self else { return }
            switch self.settings.autoRecordMode {
            case .automatic: self.startRecording(context: context, source: "detector")
            case .ask: self.notifyMeetingDetected(context)
            case .manual: break
            }
        }
        detector.onMeetingSwitched = { [weak self] context in
            guard let self, self.settings.autoRecordMode == .automatic else { return }
            self.recording.splitForCalendarHandoff(context)
        }
        detector.onMeetingEnded = { [weak self] in
            self?.stopRecording()
        }
        detector.stopDebounce = settings.stopDebounceSeconds
        detector.calendar = calendar
        detector.calendarEnabled = settings.calendarDetectionEnabled
        detector.requireCalendarForBrowser = settings.requireCalendarForBrowser
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
        // First-run check. A genuinely-new user with missing permissions gets
        // onboarding (windowed — see AppDelegate). We persist the flag in every
        // case so established/permissioned users are recognised next launch and
        // start straight into menu-bar-only mode.
        if !UserDefaults.standard.bool(forKey: Self.onboardingShownKey) {
            UserDefaults.standard.set(true, forKey: Self.onboardingShownKey)
            if !PermissionManager.shared.allGranted {
                WindowAccess.shared.open("onboarding")
            }
        }
        // Bring optional system-wide automation up if the user left it enabled
        // and the grants are in place; otherwise it parks itself.
        dictation.applySettings()
        cotyping.applySettings()
        if settings.cotypingEnabled { Task { await cotypingEngine.prewarm() } }
    }

    func prepareForTermination() async {
        if let terminationCleanupTask {
            await terminationCleanupTask.value
            return
        }
        let task = Task { @MainActor in
            interactive = false
            recording.prepareForTermination()
            detector.stop()
            audioMonitor.stop()
            sampler.stop()
            screenshots.stop()
            chat.stop()
            dictation.stop()
            cotyping.stop()
            await agentSessions.shutdownAll()
            await cotypingEngine.unload()
            await LlamaServer.shared.stop()
            await LlamaServer.embedder.stop()
            await LlamaServer.cotyping.stop()
        }
        terminationCleanupTask = task
        await task.value
    }

    // MARK: - Detection → recording glue

    /// Builds a detection context for a user-initiated recording on `detectedApp`
    /// (nil → manual), folding in the active calendar event when calendar
    /// detection is enabled and authorized — so the menu / command / banner
    /// entry points get calendar titling too.
    func recordingContext(for detectedApp: MeetingDetector.DetectedApp?) -> MeetingDetectionContext? {
        guard let detectedApp else { return nil }
        let event = (settings.calendarDetectionEnabled && calendar.hasAccess)
            ? calendar.activeCandidate(now: Date()) : nil
        return MeetingDetectionContext(
            detectedApp: detectedApp,
            calendarEvent: event,
            confidence: MeetingMatcher.confidence(hasApp: true, hasCalendar: event != nil),
            reason: "user")
    }

    /// `AudioSourceMonitor` saw an app newly start producing output. Auto-record
    /// in automatic mode only for high-confidence native meeting output or a
    /// calendar-backed native app; leave broader chat apps as banner/detector
    /// candidates so notification sounds cannot start recordings.
    private func audioMonitorDetected(_ process: AudioProcess) {
        guard !recording.isRecording, !recording.isStarting else { return }
        guard settings.autoRecordMode == .automatic, let bundleID = process.bundleID else { return }
        let calendarEvent = (settings.calendarDetectionEnabled && calendar.hasAccess)
            ? calendar.activeCandidate(now: Date()) : nil
        if let name = MeetingDetector.knownApps[bundleID] {
            guard MeetingDetector.shouldAutoRecordNativeAudioMonitor(
                bundleID: bundleID,
                calendarBacked: calendarEvent != nil) else {
                return
            }
            let detected = MeetingDetector.DetectedApp(name: name, bundleID: bundleID, pid: process.id)
            startRecording(context: detectionContext(detected, calendarEvent), source: "audio-monitor")
            return
        }
        guard let hostBundleID = MeetingDetector.hostBrowserBundleID(forAudioBundleID: bundleID) else { return }
        // The browser is already producing output (the monitor fired on it), so a
        // window-title match OR an active calendar meeting link is enough — the
        // latter catches a generic-title Google Meet the title check misses.
        let titleMatches = MeetingDetector.visibleBrowserMeeting()?.bundleID == hostBundleID
        let calendarBacked = calendarEvent?.meetingURL != nil
        guard MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: titleMatches, hasOutputAudio: true,
            calendarBacked: calendarBacked, requireCalendarForBrowser: settings.requireCalendarForBrowser)
        else { return }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: hostBundleID)
            .first?.localizedName ?? "Browser"
        let detected = MeetingDetector.DetectedApp(name: name, bundleID: hostBundleID, pid: process.id)
        startRecording(context: detectionContext(detected, calendarEvent), source: "audio-monitor")
    }

    private func detectionContext(_ app: MeetingDetector.DetectedApp,
                                  _ event: CalendarMeetingCandidate?) -> MeetingDetectionContext {
        MeetingDetectionContext(
            detectedApp: app, calendarEvent: event,
            confidence: MeetingMatcher.confidence(hasApp: true, hasCalendar: event != nil),
            reason: "audio-monitor")
    }

    private func notifyMeetingDetected(_ context: MeetingDetectionContext) {
        // M1: simple user notification via the menu bar (badge). A richer
        // UNUserNotification with a "Record" action button is a fast follow.
        lastError = nil
        NSSound.beep()
    }

    // MARK: - Library operations

    func reprocess(_ meeting: Meeting, transcribe: Bool, summarize: Bool) {
        pipeline.enqueue(meeting, transcribe: transcribe, summarize: summarize)
    }

    func saveTranscript(_ transcript: Transcript, for meeting: Meeting) throws {
        try pipeline.saveTranscript(transcript, for: meeting)
        searchIndex.reindex(meeting, storage: storage)
        if settings.semanticSearchEnabled {
            Task { try? await embeddingIndex.index(meeting) }
        }
        objectWillChange.send()
    }

    func speakerNameHints(for meeting: Meeting) -> [String] {
        let fallbackDuration = max(meeting.recordedDuration ?? 60, 60)
        let fallbackEnd = meeting.startedAt.addingTimeInterval(fallbackDuration)
        var end = meeting.endedAt.map { max($0, meeting.startedAt) } ?? fallbackEnd
        if end <= meeting.startedAt { end = fallbackEnd }
        let ocr = activityStore.ocrText(from: meeting.startedAt, to: end, maxChars: 12_000)
        return SpeakerNameHintExtractor.hints(
            calendarNames: meeting.participantNameHints ?? [],
            ocrText: ocr)
    }

    func applyTrackingSetting() {
        sampler.excludedApps = { [weak self] in self?.settings.excludedAppList ?? [] }
        if settings.trackingEnabled { sampler.start() } else { sampler.stop() }
        screenshots.restart()
    }

    /// Search hit → open the meeting; transcript hits seek the player.
    func openSearchHit(_ hit: SearchIndex.Hit) {
        if hit.kind == .segment {
            pendingSeek = hit.start
        }
        openMeeting(hit.meetingID)
    }

    /// Chat citation marker → open the cited meeting; timed markers seek the player.
    func openCitation(_ citation: ChatCitation) {
        guard let meeting = ((try? SessionLookup.find(id: citation.meetingID, in: meetings)) ?? nil) else { return }
        if let seconds = citation.seconds {
            pendingSeek = seconds
        }
        openMeeting(meeting.id)
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
}
