import SwiftUI
import Combine
import AVFoundation
import CoreGraphics

enum MeetingLibraryLoadOutcome: Sendable {
    case loaded(MeetingLibraryLoad)
    case failed(String)
    case cancelled
}

/// Central app state (the "coordinator" from the design doc §6): dependency
/// wiring, the meeting library, navigation, and the detection→recording glue.
/// The recording lifecycle itself lives in `RecordingController`; headless
/// subcommands in `HeadlessCommandRunner`; AppKit launch plumbing in
/// `AppLifecycle.swift`.
@MainActor
final class AppState: ObservableObject {

    enum NavSection: Hashable {
        case today, timeline, meetings, type, ask, agent, settings

        /// Section names accepted from the UI-test capture environment and
        /// deep links. Legacy names keep working: "capture" (the pre-split
        /// merged section) lands on Timeline, "dictation" and "cotyping" on
        /// Type, "search"/"chat" on Ask (spec §2.1), and "models" on
        /// Settings, which absorbed it as a tab (spec §2.5).
        init?(captureName: String) {
            switch captureName.lowercased() {
            case "today": self = .today
            case "timeline", "capture": self = .timeline
            case "meetings": self = .meetings
            case "type", "dictation", "cotyping", "autocomplete": self = .type
            case "ask", "search", "chat": self = .ask
            case "agent": self = .agent
            case "settings", "models": self = .settings
            default: return nil
            }
        }
    }

    /// Which tool the Type section shows. Session-sticky: preserved while
    /// navigating away so returning lands on the last-used tab.
    enum TypeTab: String {
        case dictation, cotyping

        /// Legacy capture names select their tab; anything else leaves the
        /// current tab untouched.
        init?(captureName: String) {
            switch captureName.lowercased() {
            case "dictation": self = .dictation
            case "cotyping", "autocomplete": self = .cotyping
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
    /// Hosted XCTest executes the real app entry point. It needs neither UI
    /// fixtures nor any interactive service, so return before touching the
    /// meeting library, indexes, permissions, audio, Sparkle, or the network.
    nonisolated static var isUnitTesting: Bool { UITestRuntime.isUnitTesting }

    /// UserDefaults flag: the permission onboarding has been shown once. Also
    /// read by `AppDelegate` to keep the first run windowed.
    nonisolated static let onboardingShownKey = "lokalbotv3.onboarding.shown"

    @Published var meetings: [Meeting] = []

    func removeMeetingsFromLibrary(_ ids: Set<Meeting.ID>) {
        meetings.removeAll { ids.contains($0.id) }
    }
    @Published var lastError: String?
    @Published var libraryLoadError: String?
    /// A recording or dictation start was refused because microphone access
    /// is denied at the system level. Cleared when the user opens System
    /// Settings from the recovery toast or dismisses it.
    @Published var micRecoveryNeeded = false

    /// The always-alive settings owner; services capture this, never AppState.
    let settingsStore = SettingsStore()

    /// UI-facing settings surface (views bind `$app.settings.x`). Writes flow
    /// through to `settingsStore` (which persists) and fan out to the
    /// subsystems that apply settings live.
    @Published var settings: AppSettings {
        didSet {
            applySettingsChange(from: oldValue)
        }
    }

    private func applySettingsChange(from old: AppSettings) {
        guard settings != old else { return }
        settingsStore.current = settings
        modelRoles.settingsDidChange(from: old, to: settings)
        applyDetectorSettingsChange(from: old)
        guard interactive else { return }
        applyInteractiveSettingsChange(from: old)
    }

    private func applyDetectorSettingsChange(from old: AppSettings) {
        if settings.stopDebounceSeconds != old.stopDebounceSeconds {
            detector.stopDebounce = settings.stopDebounceSeconds
        }
        if settings.calendarDetectionEnabled != old.calendarDetectionEnabled {
            detector.calendarEnabled = settings.calendarDetectionEnabled
        }
        if settings.requireCalendarForBrowser != old.requireCalendarForBrowser {
            detector.requireCalendarForBrowser = settings.requireCalendarForBrowser
        }
    }

    private func applyInteractiveSettingsChange(from old: AppSettings) {
        applyTypingSettingsChange(from: old)
        if settings.quickRecallEnabled != old.quickRecallEnabled {
            applyQuickRecallSetting()
        }
        if ScreenshotRetentionSchedule.requiresImmediatePrune(
            previousDays: old.retentionDays,
            currentDays: settings.retentionDays
        ) {
            screenshots.pruneOldScreenshots()
        }
        applyScheduledSettingsChange(from: old)
    }

    private func applyTypingSettingsChange(from old: AppSettings) {
        if Self.dictationLifecycleChanged(from: old, to: settings) {
            dictation.applySettings()
        }
        if settings.cotypingEnabled != old.cotypingEnabled {
            cotyping.applySettings()
            if !settings.cotypingEnabled { scheduleCotypingRuntimeUnload() }
        }
        if Self.cotypingRuntimeChanged(from: old, to: settings) {
            scheduleCotypingPrewarm()
        }
    }

    private func applyScheduledSettingsChange(from old: AppSettings) {
        if Self.dailyMemoryExportChanged(from: old, to: settings) {
            applyDailyMemoryExportSetting()
        }
        if Self.dayDigestChanged(from: old, to: settings) {
            applyDayDigestSetting()
        }
        if Self.screenContextChanged(from: old, to: settings) {
            applyTrackingSetting()
        }
        if Self.memoryRoutinesChanged(from: old, to: settings) {
            applyMemoryRoutineSetting()
        }
        if Self.dreamingChanged(from: old, to: settings) {
            applyDreamingSetting()
        }
    }

    private static func dictationLifecycleChanged(from old: AppSettings, to new: AppSettings) -> Bool {
        old.dictationEnabled != new.dictationEnabled
            || old.dictationShowOverlay != new.dictationShowOverlay
            || old.dictationLivePreview != new.dictationLivePreview
    }

    private static func cotypingRuntimeChanged(from old: AppSettings, to new: AppSettings) -> Bool {
        guard new.cotypingEnabled else { return false }
        return !old.cotypingEnabled
            || old.cotypingBuiltInModelID != new.cotypingBuiltInModelID
            || old.cotypingInProcessRuntime != new.cotypingInProcessRuntime
            || old.customBuiltInModels != new.customBuiltInModels
    }

    private static func dailyMemoryExportChanged(from old: AppSettings,
                                                 to new: AppSettings) -> Bool {
        old.dailyMemoryExportEnabled != new.dailyMemoryExportEnabled
            || old.dailyMemoryExportFolder != new.dailyMemoryExportFolder
            || old.dailyMemoryExportFormat != new.dailyMemoryExportFormat
            || old.dailyMemoryExportHour != new.dailyMemoryExportHour
    }

    /// The custom prompt is deliberately absent: it is read fresh from
    /// `settings` at generation time, so editing it never resets the scheduler.
    private static func dayDigestChanged(from old: AppSettings,
                                         to new: AppSettings) -> Bool {
        old.dayDigestAutoEnabled != new.dayDigestAutoEnabled
            || old.dayDigestHour != new.dayDigestHour
    }

    private static func screenContextChanged(from old: AppSettings,
                                             to new: AppSettings) -> Bool {
        old.trackingEnabled != new.trackingEnabled
            || old.effectiveScreenContextCaptureMode != new.effectiveScreenContextCaptureMode
            || old.screenshotIntervalMinutes != new.screenshotIntervalMinutes
            || old.meetingVisualContextEnabled != new.meetingVisualContextEnabled
    }

    private static func memoryRoutinesChanged(from old: AppSettings,
                                              to new: AppSettings) -> Bool {
        old.memoryRoutinesEnabled != new.memoryRoutinesEnabled
            || old.memoryRoutineFolder != new.memoryRoutineFolder
            || old.enabledMemoryRoutines != new.enabledMemoryRoutines
            || old.memoryRoutineHour != new.memoryRoutineHour
            || old.memoryRoutineWeekday != new.memoryRoutineWeekday
    }

    private static func dreamingChanged(from old: AppSettings,
                                        to new: AppSettings) -> Bool {
        old.dreamingEnabled != new.dreamingEnabled
            || old.dreamingHour != new.dreamingHour
            || old.dreamingFirstEligibleDayKey != new.dreamingFirstEligibleDayKey
    }

    // Navigation (main window): sidebar section and selected meeting.
    @Published var navSection: NavSection = .today
    private static let typeTabDefaultsKey = "lokalbotv3.type.selectedTab"
    private static var navigationDefaults: UserDefaults {
        if let suite = UITestRuntime.defaultsSuiteName,
           let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        return .standard
    }
    @Published var typeTab: TypeTab = .dictation {
        didSet { Self.navigationDefaults.set(typeTab.rawValue, forKey: Self.typeTabDefaultsKey) }
    }
    @Published var settingsTab: SettingsTab = .general
    /// Ask's retrieval choice survives NavigationSplitView remounts while the
    /// app is running. Explicit handoffs and conversation selections still
    /// switch back to Ask before presenting their content.
    @Published var askMode: AskMode = .ask
    @Published var selectedMeetingIDs: Set<Meeting.ID> = []
    /// The meeting whose page-level find bar is visible. Keeping presentation
    /// in shared observable state makes menu/AppKit requests and the rendered
    /// NavigationSplitView consume one source of truth.
    @Published private(set) var presentedMeetingSearchID: Meeting.ID?
    @Published private(set) var meetingPageSearchRequestRevision = 0

    /// A day handed to the Ask section (the old Timeline "Ask" tab, spec
    /// §2.2): rendered as a removable chip, and prepended to escalated
    /// queries so the assistant scopes its answer to that day.
    @Published var askDayScope: Date?
    /// Atomic, destination-scoped payloads for cross-surface navigation.
    private(set) lazy var navigationHandoff = NavigationHandoff()

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
    func openAsk(query: String = "", dayScope: Date? = nil,
                 screenSnapshotIDs: [Int64] = [], submit: Bool = false) {
        navigationHandoff.stageAsk(
            query: query,
            dayScope: dayScope,
            screenSnapshotIDs: screenSnapshotIDs,
            submit: submit)
        navSection = .ask
    }

    func openAgent(_ context: AgentLaunchContext? = nil) {
        navigationHandoff.stageAgent(context)
        if let prompt = context?.prompt {
            agentSessions.ensureSelectedController().draft = prompt
        }
        navSection = .agent
    }

    /// Open one meeting in the Meetings section — the deep-link target
    /// for search hits, menu-bar recents, and palette recents.
    func openMeeting(_ id: Meeting.ID, seek: TimeInterval? = nil) {
        navigationHandoff.stageMeeting(id, seek: seek)
        selectedMeetingIDs = [id]
        navSection = .meetings
    }

    var canSearchSelectedMeeting: Bool {
        navSection == .meetings && selectedMeeting?.endedAt != nil
    }

    func requestSelectedMeetingSearch() {
        guard canSearchSelectedMeeting, let meeting = selectedMeeting else { return }
        presentedMeetingSearchID = meeting.id
        meetingPageSearchRequestRevision &+= 1
    }

    func dismissMeetingSearch(for meetingID: Meeting.ID) {
        guard presentedMeetingSearchID == meetingID else { return }
        presentedMeetingSearchID = nil
    }

    func selectDefaultMeetingIfNeeded() {
        guard selectedMeetingIDs.isEmpty else { return }
        if let live = currentMeeting {
            openMeeting(live.id)
        } else if let completed = meetings.first(where: { meeting in
            meeting.endedAt != nil && pipeline.stages[meeting.id] == nil
        }) ?? meetings.first(where: { $0.endedAt != nil }) {
            openMeeting(completed.id)
        }
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
    private(set) lazy var outcomeIndex = OutcomeIndex(storage: storage)
    private(set) lazy var cotypingLearning = CotypingLearningStore(storageRoot: storage.rootURL)
    let detector = MeetingDetector()
    let audioMonitor = AudioSourceMonitor()
    /// External-agent access: Privacy marker plus the local-model wake watcher.
    private(set) lazy var agentAccess = AgentAccessManager(
        storage: storage,
        settings: { [weak self] in self?.settings ?? AppSettings.load() },
        onError: { [weak self] message in self?.lastError = message })
    /// Screen-memory access is intentionally separate from meeting-library
    /// access: enabling one capability never grants the other.
    private(set) lazy var screenMemoryAccess = ScreenMemoryAccessManager(
        gate: ScreenMemoryAccessGate(root: storage.rootURL))
    private(set) lazy var quickRecallHotKey: QuickRecallHotKeyController = {
        let controller = QuickRecallHotKeyController()
        controller.onInvoke = { WindowAccess.shared.open("quick-recall") }
        return controller
    }()

    var backgroundAutomationIsIdle: Bool {
        !recording.isRecording
            && !recording.isStarting
            && !dictation.isStarting
            && !dictation.state.isWorking
            && !cotyping.state.isGenerating
            && !pipeline.hasActiveWork
    }

    let dailyMemoryExportScheduler = DailyMemoryExportScheduler()
    private(set) lazy var memoryRoutines = MemoryRoutineScheduler(
        storageRoot: storage.rootURL,
        databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"),
        canRun: { [weak self] in
            self?.backgroundAutomationIsIdle ?? false
        })
    /// Overnight dreaming: the scheduler is observed by Settings (progress /
    /// last-run), the store is read by Today, and `latestDreamReport` lets an
    /// open Today window pick up a dream that finishes while it's visible.
    @Published var latestDreamReport: DreamReport?
    /// Settings' user-managed pin controls. The store remains the source of
    /// truth; mutations reload it before saving to avoid stale-view writes.
    @Published private(set) var dreamMemory: DreamMemory?

    func updateDreamMemory(_ value: DreamMemory?) {
        dreamMemory = value
    }
    private(set) lazy var dreamStore = DreamStore(root: storage.rootURL)
    private(set) lazy var dreaming: DreamScheduler = {
        let scheduler = DreamScheduler()
        invalidationBridge.observe(scheduler.objectWillChange)
        return scheduler
    }()
    /// Read-only calendar access (EventKit): confirms meetings and titles
    /// recordings. Concrete type so the settings UI observes its permission
    /// state; handed to the detector as the `CalendarEventProviding` seam.
    let calendar = EventKitCalendarEventProvider()
    var cachedSearchIndex: SearchIndex?
    var searchIndex: SearchIndex {
        if let cachedSearchIndex { return cachedSearchIndex }
        let created = SearchIndex(
            databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"))
        for meetingID in deletedMeetingIDs { created.noteDeletion(meetingID) }
        cachedSearchIndex = created
        return created
    }
    private(set) lazy var activityStore = ActivityStore(
        databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"))
    private(set) lazy var sampler = ActivitySampler(store: activityStore)
    var cachedEmbeddingIndex: EmbeddingIndex?
    var embeddingIndex: EmbeddingIndex {
        if let cachedEmbeddingIndex { return cachedEmbeddingIndex }
        let created = EmbeddingIndex(
            databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"),
            storage: storage)
        for meetingID in deletedMeetingIDs { created.noteDeletion(meetingID) }
        cachedEmbeddingIndex = created
        return created
    }
    private(set) lazy var screenshots = ScreenshotService(
        store: activityStore, storage: storage, sampler: sampler,
        isMeetingRecordingActive: { [weak self] in
            guard let self else { return false }
            return self.recording.isRecording || self.recording.isStarting
        }, activeMeetingID: { [weak self] in
            self?.recording.currentMeeting?.id
        }, isHighPriorityInteractionActive: { [weak self] in
            guard let self else { return false }
            if self.dictation.state.isWorking { return true }
            if case .generating = self.cotyping.state { return true }
            return false
        }) { [store = settingsStore] in
        store.current
    }
    private(set) lazy var pipelineJobStore = PipelineJobStore(
        databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"))
    /// Backend selection, preparation, privacy policy, leases, and recovery
    /// for every feature that uses LokalBot's Think role.
    private(set) lazy var thinkExecution = ThinkExecution(storage: storage)
    private(set) lazy var pipeline = ProcessingPipeline(
        storage: storage,
        jobStore: pipelineJobStore,
        settings: { [store = settingsStore] in store.current },
        thinkExecution: thinkExecution)
    /// Canonical state machine for Transcribe, Think, and Autocomplete.
    private(set) lazy var modelRoles = ModelRoles(
        settings: { [store = settingsStore] in store.current },
        storage: storage,
        onReadinessChanged: { [weak self] in
            self?.processMeetingsWaitingForModels()
        })
    /// One Day Digest lifecycle for manual, scheduled, and headless callers.
    /// It owns evidence collection, journal state, freshness, and repair policy.
    private(set) lazy var dayDigest = DayDigestLifecycle(
        storage: storage,
        activityStore: activityStore,
        pipeline: pipeline,
        meetings: { [weak self] in
            guard let self else { return [] }
            return (self.currentMeeting.map { [$0] } ?? []) + self.meetings
        },
        settings: { [store = settingsStore] in store.current })
    /// Meeting-recording lifecycle: recorders, watchdog, timer tick, prewarm.
    private(set) lazy var recording = RecordingController(
        storage: storage,
        settingsStore: settingsStore,
        audioMonitor: audioMonitor,
        pipeline: pipeline,
        isInteractive: { [weak self] in self?.interactive ?? false },
        onError: { [weak self] message in
            guard let message else {
                // Withdraw only the silent-capture advisory, never a newer error.
                if self?.lastError == RecordingController.silentSystemAudioMessage {
                    self?.lastError = nil
                }
                return
            }
            self?.lastError = message
        },
        onMicPermissionDenied: { [weak self] in self?.micRecoveryNeeded = true },
        onMeetingFinished: { [weak self] meeting in self?.meetings.insert(meeting, at: 0) })
    /// Press-and-speak composition. Every dictation is treated as a writing
    /// request: local ASR captures the instruction, the configured composition
    /// LLM writes against ephemeral focused-window context, and focus-safe
    /// delivery inserts it.
    private(set) lazy var dictation = DictationCoordinator(
        storageRoot: storage.rootURL,
        settingsProvider: { [store = settingsStore] in store.current },
        makeTextEngine: { [weak self] in
            guard let self else {
                throw TextEngineError.unavailable("LokalBot is shutting down.")
            }
            let config = self.settingsStore.current.dictationCompositionTextEngineSettings
            return try await self.thinkExecution.makeTextEngine(
                config,
                priority: .interactive,
                purpose: "dictation compose")
        },
        canStart: { [weak self] in
            guard let self else { return false }
            return !self.recording.isRecording
                && !self.recording.isStarting
                && self.pendingRecordingStart == nil
        },
        onBusy: { [weak self] in
            self?.lastError = "Stop the current meeting recording before starting dictation."
        },
        onError: { [weak self] message in
            self?.lastError = message
        },
        onMicPermissionDenied: { [weak self] in
            self?.micRecoveryNeeded = true
        })
    /// Cotyping (inline AI autocomplete). Always runs its own model on the
    /// dedicated `LlamaServer.cotyping` instance so it never thrashes the
    /// shared summarizer server. Resolved per-completion, so changes apply live.
    private(set) lazy var cotypingEngine = CotypingEngineSelector(
        http: CotypingEngine(
            makeEngine: { [weak self] in
                guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
                return try await self.thinkExecution.makeTextEngine(
                    self.settings.cotypingTextEngineSettings,
                    server: .cotyping,
                    priority: .interactive,
                    purpose: "cotyping")
            },
            stopRuntime: { await LlamaServer.cotyping.stop() }),
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
            return try await self.thinkExecution.makeTextEngine(
                self.settings,
                priority: .interactive,
                purpose: "chat")
        },
        tools: MeetingChatTools(
            meetings: { [weak self] in self?.meetings ?? [] },
            storage: storage,
            searchIndex: searchIndex,
            embeddingIndex: embeddingIndex,
            activityStore: activityStore,
            settings: { [store = settingsStore] in store.current }),
        store: ChatStore(rootURL: storage.rootURL),
        workMemory: { [weak self] in
            guard let self else { return "" }
            return ChatPrompt.workMemoryContext(
                memory: try? self.dreamStore.loadMemory(),
                dreamingEnabled: self.settings.dreamingEnabled)
        })

    // Agent Mode (pi). Installer and tab manager are cheap; each tab lazily
    // spawns its own controller/process when AgentView mounts it.
    let agentInstaller = AgentRuntimeInstaller()
    private(set) lazy var agentSessions = AgentSessionTabs(
        settings: { [store = settingsStore] in store.current },
        storage: storage,
        thinkExecution: thinkExecution)
    var agentController: AgentSessionController {
        agentSessions.ensureSelectedController()
    }

    private var recordingStatusObserver: AnyCancellable?
    private var audioMonitorObserver: AnyCancellable?
    private lazy var invalidationBridge = AppStateInvalidationBridge { [weak self] in
        self?.objectWillChange.send()
    }
    /// True only on the real interactive launch path (not headless / UI test) —
    /// gates recording notifications and first-run onboarding.
    var interactive = false
    var terminationCleanupTask: Task<Void, Never>?
    /// Serializes cotyping model lifecycle transitions. A disable must finish
    /// unloading both runtimes before a rapid re-enable can prewarm a fresh
    /// model, otherwise the old and new routes can overlap in memory.
    var cotypingRuntimeTask: Task<Void, Never>?
    var cotypingRuntimeTaskID: UUID?
    var libraryLoadTask: Task<Void, Never>?
    var embeddingIndexTasks: [Meeting.ID: (token: UUID, task: Task<Void, Never>)] = [:]
    var indexCleanupTasks: [Meeting.ID: (token: UUID, task: Task<Void, Never>)] = [:]
    var deletedMeetingIDs: Set<Meeting.ID> = []
    @Published var libraryReady = false
    var pendingRecordingStart: (
        context: MeetingDetectionContext?,
        source: String,
        systemAudioPolicy: RecordingSystemAudioPolicy
    )?
    lazy var searchIndexWorkQueue = SearchIndexWorkQueue(
        databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"),
        rootURL: storage.rootURL)

    // Recording facades — views observe AppState only.
    var isRecording: Bool { recording.isRecording }
    var currentMeeting: Meeting? { recording.currentMeeting }

    func startRecording(
        context: MeetingDetectionContext? = nil,
        source: String = "ui",
        systemAudioPolicy: RecordingSystemAudioPolicy = .meetingAppWhenAvailable
    ) {
        RecordingNotifier.shared.invalidateMeetingDetections()
        guard !dictation.isStarting, !dictation.state.isWorking else {
            lastError = "Finish or cancel dictation before starting a meeting recording."
            return
        }
        guard libraryReady else {
            if let libraryLoadError {
                pendingRecordingStart = nil
                lastError = libraryLoadError
                return
            }
            pendingRecordingStart = (context, source, systemAudioPolicy)
            lastError = "Preparing your meeting library; recording will start when it is ready."
            return
        }
        recording.start(
            context: context,
            source: source,
            systemAudioPolicy: systemAudioPolicy)
    }

    func stopRecording(process: Bool = true) {
        if !libraryReady {
            pendingRecordingStart = nil
            return
        }
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
        typeTab = Self.initialTypeTab()
        if Self.isUnitTesting { return }
        reportStartupNotices()
        let headlessCommand = HeadlessCommand.requested
        let needsSynchronousLibrary = headlessCommand != nil || Self.isUITesting
        if needsSynchronousLibrary { loadLibrarySynchronously() }
        LiveMeetingTranscriber.sweepOrphanedSnapshots(storageRoot: storage.rootURL)
        configureInvalidationObservers()
        configureArtifactCallback()
        if needsSynchronousLibrary && libraryReady {
            searchIndex.reindexAll(meetings, storage: storage)
        }
        if let command = headlessCommand {
            HeadlessCommandRunner(app: self).run(command)
            return
        }
        // UI tests render against pre-seeded fixtures, not a real audio/Sparkle
        // session — bail out before any subsystem reaches for the mic, the
        // process list, or the network.
        if Self.isUITesting { return }
        startInteractiveRuntime()
    }

    private static func initialTypeTab() -> TypeTab {
        if let raw = navigationDefaults.string(forKey: typeTabDefaultsKey),
           let stored = TypeTab(rawValue: raw) {
            return stored
        }
        // Existing installs retain Dictation; genuinely new installs lead
        // with the approved Autocomplete experience.
        return navigationDefaults.bool(forKey: onboardingShownKey)
            ? .dictation : .cotyping
    }

    private func reportStartupNotices() {
        reportCorruptedSettings()
        if let migrationNotice = DataMigration.consumeFailureNotice() {
            lastError = migrationNotice
        }
    }

    private func reportCorruptedSettings() {
        // Settings corruption is a privacy event: silently resetting a field
        // such as screenshot capture changes what the app records.
        guard !settings.corruptedSettingsKeys.isEmpty else { return }
        let keys = settings.corruptedSettingsKeys.joined(separator: ", ")
        lokalbotLog("settings decode fell back to defaults for: \(keys)")
        lastError = settings.corruptedSettingsKeys == [AppSettings.wholeStoreCorruptionMarker]
            ? "Saved settings could not be read and were reset to defaults. Review Settings — especially Privacy and Recording."
            : "Some saved settings could not be read and were reset to defaults (\(keys)). Review them in Settings."
    }

    private func loadLibrarySynchronously() {
        do {
            let load = try storage.loadMeetingLibrary()
            meetings = load.meetings
            libraryReady = true
            applyLibraryIssues(load.issues)
            outcomeIndex.refresh(meetings: meetings)
        } catch {
            handleLibraryLoadFailure(error.localizedDescription)
        }
    }

    private func configureInvalidationObservers() {
        // Views observe AppState only; forward meaningful child changes.
        invalidationBridge.observe(pipeline.objectWillChange)
        invalidationBridge.observe(outcomeIndex.objectWillChange)
        invalidationBridge.observe(dictationInvalidations)
        invalidationBridge.observe(recordingLifecycleInvalidations)
        recordingStatusObserver = recording.$status
            .map(Self.activeMeetingID)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] meetingID in
                self?.meetingRecordingStateDidChange(active: meetingID != nil)
            }
        invalidationBridge.observe(audioMonitor.objectWillChange)
        invalidationBridge.observe(calendar.objectWillChange)
        invalidationBridge.observe(modelRoles.objectWillChange)
        invalidationBridge.observe(navigationHandoff.objectWillChange)
    }

    private var dictationInvalidations: AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            dictation.$state.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dictation.$isStarting.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dictation.$isShortcutMonitoringActive.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dictation.$lastTranscript.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dictation.$lastComposedText.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dictation.$lastEngine.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]).eraseToAnyPublisher()
    }

    private var recordingLifecycleInvalidations: AnyPublisher<Void, Never> {
        // Exclude RecordingController's one-second clock; timer labels observe
        // it directly and do not need to invalidate the whole window.
        Publishers.CombineLatest(recording.$status, recording.$currentMeeting)
            .dropFirst()
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    private static func activeMeetingID(from status: RecordingController.Status) -> UUID? {
        if case .recording(let meetingID) = status { return meetingID }
        return nil
    }

    private func configureArtifactCallback() {
        pipeline.onArtifactsWritten = { [weak self] meeting in
            self?.artifactsWereWritten(for: meeting)
        }
    }

    private func artifactsWereWritten(for meeting: Meeting) {
        outcomeIndex.refresh(meeting: meeting)
        reindexSearchInBackground(meeting)
        if settings.semanticSearchEnabled { reindexEmbeddingInBackground(meeting) }
        memoryRoutines.tick()
        invalidateDreamIfNeeded(for: meeting)
    }

    private func invalidateDreamIfNeeded(for meeting: Meeting) {
        // A parked recovery job can finish after dreaming wrote that day's
        // report. Remove the marker so the next quiet tick includes it.
        let dayKey = DreamDay.key(for: meeting.startedAt, calendar: .current)
        let reportURL = dreamStore.reportJSONURL(forDayKey: dayKey)
        let activationKey = settings.dreamingFirstEligibleDayKey ?? dayKey
        guard settings.dreamingEnabled,
              dayKey >= activationKey,
              FileManager.default.fileExists(atPath: reportURL.path) else { return }
        do {
            try dreamStore.invalidateReport(forDayKey: dayKey)
        } catch {
            lastError = "Could not refresh the dream for \(dayKey): "
                + error.localizedDescription
        }
        latestDreamReport = dreamStore.latestReport()
        dreaming.reconsiderReports()
    }

    private func startInteractiveRuntime() {
        interactive = true
        RecordingNotifier.shared.bootstrap()
        applyTrackingSetting()
        configureDetectorCallbacks()
        detector.stopDebounce = settings.stopDebounceSeconds
        detector.calendar = calendar
        detector.calendarEnabled = settings.calendarDetectionEnabled
        detector.requireCalendarForBrowser = settings.requireCalendarForBrowser
        startInteractiveServices()
        applyStartupSettings()
        showOnboardingIfNeeded()
        dictation.applySettings()
        cotyping.applySettings()
        if settings.cotypingEnabled { scheduleCotypingPrewarm() }
        loadLibraryInBackground()
    }

    private func configureDetectorCallbacks() {
        detector.onMeetingStarted = { [weak self] context in
            self?.meetingDetectorStarted(context)
        }
        detector.onMeetingSwitched = { [weak self] context in
            self?.meetingDetectorSwitched(context)
        }
        detector.onMeetingEnded = { [weak self] in
            RecordingNotifier.shared.invalidateMeetingDetections()
            self?.stopRecording()
        }
    }

    private func meetingDetectorStarted(_ context: MeetingDetectionContext) {
        switch settings.autoRecordMode {
        case .automatic: startRecording(context: context, source: "detector")
        case .ask: notifyMeetingDetected(context)
        case .manual: RecordingNotifier.shared.invalidateMeetingDetections()
        }
    }

    private func meetingDetectorSwitched(_ context: MeetingDetectionContext) {
        switch settings.autoRecordMode {
        case .automatic:
            RecordingNotifier.shared.invalidateMeetingDetections()
            recording.splitForCalendarHandoff(context)
        case .ask:
            if recording.isRecording || recording.isStarting {
                RecordingNotifier.shared.invalidateMeetingDetections()
            } else {
                notifyMeetingDetected(context)
            }
        case .manual:
            RecordingNotifier.shared.invalidateMeetingDetections()
        }
    }

    private func startInteractiveServices() {
        // Audio output complements the mic-in-use meeting signal, including
        // meetings where the local microphone is muted.
        audioMonitor.start()
        audioMonitorObserver = audioMonitor.$detectedProcess
            .compactMap { $0 }
            .sink { [weak self] process in self?.audioMonitorDetected(process) }
        detector.start()
        AppUpdateManager.shared.start()
        agentAccess.start()
        screenMemoryAccess.start()
    }

    private func applyStartupSettings() {
        applyQuickRecallSetting()
        applyDailyMemoryExportSetting()
        applyDayDigestSetting()
        applyMemoryRoutineSetting()
        applyDreamingSetting()
    }

    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.onboardingShownKey) else { return }
        if PermissionManager.shared.allGranted {
            UserDefaults.standard.set(true, forKey: Self.onboardingShownKey)
        } else {
            WindowAccess.shared.open("onboarding")
        }
    }

}
