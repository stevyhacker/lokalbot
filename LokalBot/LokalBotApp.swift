import SwiftUI
import Combine
import AVFoundation

/// Whether this launch should come up menu-bar-only (accessory: no Dock icon,
/// no window). Computed identically in the pre-launch entry point (to disable
/// window restoration before AppKit reads the flag) and in the app delegate (to
/// set the activation policy). "Established" = has seen onboarding OR already
/// granted every permission, so upgrades that predate the onboarding flag still
/// go menu-bar-only; only a genuinely-new user (and UI tests) stays windowed.
func lokalbotLaunchesMenuBarOnly() -> Bool {
    guard !AppState.isUITesting else { return false }
    let onboarded = UserDefaults.standard.bool(forKey: AppState.onboardingShownKey)
        || AppPermission.coreCases.allSatisfy { $0.isGranted }
    return AppSettings.load().menuBarOnly && onboarded
}

/// Process entry point. Disables AppKit window restoration *before* SwiftUI
/// launches when starting menu-bar-only — `applicationWillFinishLaunching` runs
/// after AppKit has already read the flag, so a previously-open window would be
/// restored and force the Dock icon back on. Setting it pre-launch is the only
/// reliable point.
@main
enum LokalBotMain {
    static func main() {
        // Carry a prior LokalBotV2 install's data forward before anything reads
        // a store: settings are loaded below (via lokalbotLaunchesMenuBarOnly),
        // and AppState builds StorageManager/SearchIndex right after.
        DataMigration.runIfNeeded()
        UserDefaults.standard.set(lokalbotLaunchesMenuBarOnly(),
                                  forKey: "ApplePersistenceIgnoreState")
        LokalBotV3App.main()
    }
}

struct LokalBotV3App: App {
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

#if !LOKALBOTV3_UI_TEST_HOST
        MenuBarExtra {
            MenuBarView()
                .environmentObject(app)
        } label: {
            MenuBarLabel(app: app)
        }
        .menuBarExtraStyle(.window)
#endif

        Settings {
            SettingsView()
                .environmentObject(app)
        }
    }

    private var mainWindow: some View {
        MainWindowView()
            .environmentObject(app)
            .brandTinted()
    }
}

// MARK: - Menu-bar-only plumbing

/// Bridges AppKit launch + window lifecycle into the menu-bar-only experience.
/// SwiftUI alone can't suppress the launch window on macOS 14, so the Dock /
/// activation policy is driven from here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var appState: AppState?

    private var uiTestWindow: NSWindow?

    /// Hides the Dock icon for a menu-bar-only start. Setting `.accessory` this
    /// early also stops SwiftUI from auto-opening the launch window; restoration
    /// was already disabled in `LokalBotMain`. UI tests and not-yet-onboarded
    /// users stay windowed — see `lokalbotLaunchesMenuBarOnly()`.
    func applicationWillFinishLaunching(_ notification: Notification) {
        if AppState.isUITesting {
            NSApp.setActivationPolicy(.regular)
            return
        }
        if lokalbotLaunchesMenuBarOnly() {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Keep the Dock icon in sync with what's on screen: a real (titled) window
    /// → show the Dock icon + app menu for full window UX; nothing open → fall
    /// back to a pure menu-bar accessory.
    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppState.isUITesting {
            NSApp.setActivationPolicy(.regular)
            let app = Self.appState ?? AppState()
            Self.appState = app
#if LOKALBOTV3_UI_TEST_HOST
            applyCaptureEnvironment(to: app)
#endif
            openUITestWindow(app: app)
            forceActivateForUITests()
            return
        }
        // macOS may still restore/auto-open the main window at launch despite
        // `.accessory`; for a menu-bar-only start, evict any window that appears
        // in the first moments (the user can't have opened one yet).
        if lokalbotLaunchesMenuBarOnly() {
            DispatchQueue.main.async { DockPolicy.beginLaunchSuppression() }
        }
        let center = NotificationCenter.default
        for name: NSNotification.Name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // `willClose` fires while the window still reports visible —
                // re-evaluate on the next tick once it's actually gone.
                DispatchQueue.main.async { DockPolicy.sync() }
            }
        }
    }

    /// Reopening the app (Finder/Launchpad relaunch, Dock click) with nothing on
    /// screen brings the main window back instead of being a silent no-op.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { WindowAccess.shared.open("main") }
        return true
    }

    @MainActor
    private func openUITestWindow(app: AppState) {
        if let uiTestWindow {
            uiTestWindow.makeKeyAndOrderFront(nil)
            uiTestWindow.orderFrontRegardless()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "LokalBot"
        window.identifier = NSUserInterfaceItemIdentifier("main.window")
        let hostingView = NSHostingView(
            rootView: MainWindowView()
                .environmentObject(app)
                .brandTinted())
        hostingView.identifier = NSUserInterfaceItemIdentifier("main.window.host")
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        uiTestWindow = window
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        window.orderFrontRegardless()
    }

#if LOKALBOTV3_UI_TEST_HOST
    /// Screenshot/scripting hook for the UI-test host: a few env vars let an
    /// external capture script land the window on a specific section with a
    /// meeting preselected, without synthetic input (no Accessibility needed).
    /// A no-op unless the vars are set, so the XCUITest suite is unaffected, and
    /// compiled out of every non-host build.
    @MainActor
    private func applyCaptureEnvironment(to app: AppState) {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["LOKALBOTV3_INITIAL_SECTION"],
           let section = AppState.NavSection(captureName: raw) {
            app.navSection = section
        }
        if env["LOKALBOTV3_SELECT_FIRST"] == "1", let first = app.meetings.first {
            app.selectedMeetingIDs = [first.id]
        }
        if let raw = env["LOKALBOTV3_SELECT_INDEX"], let idx = Int(raw) {
            let ordered = app.meetings.sorted { $0.startedAt > $1.startedAt }
            if ordered.indices.contains(idx) { app.selectedMeetingIDs = [ordered[idx].id] }
        }
        if env["LOKALBOTV3_DISMISS_ONBOARDING"] == "1" {
            UserDefaults.standard.set(true, forKey: "lokalbotv3.gettingStartedDismissed")
        }
    }
#endif

    private func forceActivateForUITests() {
        for delay: Double in [0, 0.15, 0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                NSApp.setActivationPolicy(.regular)
                NSApp.unhide(nil)
                if let window = self?.uiTestWindow {
                    window.makeKeyAndOrderFront(nil)
                    window.makeMain()
                    window.orderFrontRegardless()
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// Drives the Dock/menu-bar activation policy from the current setting and the
/// windows on screen: accessory (menu-bar-only) unless the user opted into a
/// Dock icon or a real window is open. Also the launch-time backstop that evicts
/// windows macOS restores behind a menu-bar-only start.
@MainActor
enum DockPolicy {
    /// True from a menu-bar-only launch until the first explicit user-initiated
    /// open. While set, any titled window on screen was restored or auto-opened
    /// by macOS (the user hasn't asked for one yet) and is evicted — `.accessory`
    /// and `ApplePersistenceIgnoreState` don't reliably stop that restore, so
    /// this is the deterministic backstop. Cleared by `WindowAccess.open`.
    static var evictRestoredWindows = false

    /// Start evicting restored/auto windows after a menu-bar-only launch. Sweeps
    /// a few times to catch windows SwiftUI restores asynchronously (or without
    /// firing a key notification); the flag itself persists until the first real
    /// open, so even a late restore is caught.
    static func beginLaunchSuppression() {
        evictRestoredWindows = true
        for delay: Double in [0, 0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { sync() }
        }
    }

    static func sync() {
        guard !AppState.isUITesting else { return }
        let menuBarOnly = AppSettings.load().menuBarOnly

        if menuBarOnly {
            for window in NSApp.windows where isContentWindow(window) {
                window.isRestorable = false                 // never restore in menu-bar mode
                if evictRestoredWindows { window.close() }   // restored/auto → evict
            }
            if evictRestoredWindows { setPolicy(.accessory); return }
        }

        // The menu bar popover is a borderless, non-normal-level panel; only
        // titled, normal-level windows (main / onboarding / settings) count.
        let hasWindow = NSApp.windows.contains(where: isContentWindow)
        setPolicy((!menuBarOnly || hasWindow) ? .regular : .accessory)
    }

    private static func isContentWindow(_ window: NSWindow) -> Bool {
        window.isVisible && window.styleMask.contains(.titled) && window.level == .normal
    }

    private static func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }
}

/// Opens SwiftUI windows from non-View code (AppDelegate, AppState). SwiftUI's
/// `openWindow` only exists inside the View tree, so views register it here and
/// requests made before a view is alive are queued and flushed on registration.
@MainActor
final class WindowAccess {
    static let shared = WindowAccess()

    private var opener: ((String) -> Void)?
    private var pending: [String] = []

    /// Called from the first view that comes alive (the menu bar label at
    /// launch, then the popover/window). Flushes anything queued before now.
    func register(_ opener: @escaping (String) -> Void) {
        self.opener = opener
        let queued = pending
        pending.removeAll()
        queued.forEach(open)
    }

    func open(_ id: String) {
        // An explicit, user-initiated open: cancel any launch-time window
        // eviction, then switch to a regular, Dock-visible app so the window
        // gets standard chrome and the app menu. `willClose` drops back to
        // accessory afterwards when menu-bar-only.
        DockPolicy.evictRestoredWindows = false
        guard let application = NSApp else {
            pending.append(id)
            return
        }
        application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)
        if id == "main",
           let existing = application.windows.first(where: { $0.isVisible && $0.title == "LokalBot" }) {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        if let opener {
            opener(id)
        } else {
            pending.append(id)
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
        case meetings, timeline, cotyping, chat, search, models, settings
#if LOKALBOTV3_UI_TEST_HOST
        init?(captureName: String) {
            switch captureName.lowercased() {
            case "meetings": self = .meetings
            case "timeline": self = .timeline
            case "cotyping": self = .cotyping
            case "chat": self = .chat
            case "search": self = .search
            case "models": self = .models
            case "settings": self = .settings
            default: return nil
            }
        }
#endif
    }

    /// True when launched by an XCUITest harness — gates the side-effectful
    /// startup paths (Core Audio polling, accessibility-trusted detector,
    /// Sparkle, periodic screenshots) so the UI renders against synthetic
    /// data without touching real audio, TCC, or the network.
    nonisolated static var isUITesting: Bool { UITestRuntime.isEnabled }

    /// UserDefaults flag: the permission onboarding has been shown once. Also
    /// read by `AppDelegate` to keep the first run windowed.
    nonisolated static let onboardingShownKey = "lokalbotv3.onboarding.shown"

    @Published private(set) var status: Status = .idle
    @Published private(set) var meetings: [Meeting] = []
    @Published var lastError: String?
    @Published var settings = AppSettings.load() {
        didSet {
            settings.save()
            detector.stopDebounce = settings.stopDebounceSeconds
            detector.calendarEnabled = settings.calendarDetectionEnabled
            detector.requireCalendarForBrowser = settings.requireCalendarForBrowser
            if interactive { cotyping.applySettings() }
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
        store: activityStore, storage: storage, sampler: sampler) { [weak self] in
        self?.settings ?? AppSettings()
    }
    private(set) lazy var pipeline = ProcessingPipeline(storage: storage) { [weak self] in
        self?.settings ?? AppSettings()
    }
    /// Cotyping (inline AI autocomplete). By default it reuses the summarizer's
    /// `TextEngine`; when a separate cotyping model is enabled it runs on the
    /// dedicated `LlamaServer.cotyping` instance so it never thrashes the
    /// shared server. Resolved per-completion, so changes apply live.
    private(set) lazy var cotypingEngine = CotypingEngine(makeEngine: { [weak self] in
        guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
        return try await self.pipeline.makeTextEngine(
            self.settings.cotypingTextEngineSettings,
            server: self.settings.cotypingUseSeparateModel ? .cotyping : .shared)
    })
    private(set) lazy var cotyping = CotypingCoordinator(
        engine: cotypingEngine,
        settingsProvider: { [weak self] in self?.settings ?? AppSettings() },
        learningStore: cotypingLearning)

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
            settings: { [weak self] in self?.settings ?? AppSettings() }),
        store: ChatStore(rootURL: storage.rootURL))

    private let micRecorder = MicRecorder()
    private let systemRecorder = SystemAudioRecorder()
    /// The live recording (shown at the top of the library while running).
    @Published private(set) var currentMeeting: Meeting?
    private var pipelineObserver: AnyCancellable?
    private var audioMonitorObserver: AnyCancellable?
    private var audioMonitorChangeForwarder: AnyCancellable?
    private var calendarObserver: AnyCancellable?
    private var transcriptionPrewarmTask: Task<Void, Never>?
    /// Calendar event id + stop time of the last calendar-backed recording, so
    /// the same scheduled meeting can't immediately re-record (helper-PID churn,
    /// brief audio drops). See `MeetingMatcher.shouldSuppressRepeat`.
    private var lastCalendarEventID: String?
    private var lastCalendarEventEndedAt: Date?
    private static let calendarRepeatCooldown: TimeInterval = 5 * 60

    /// Ticks once a second while recording so the menu bar timer (and popover)
    /// stay live even with no window open. Nil when idle.
    private var recordingTick: AnyCancellable?
    /// Drives `elapsed`; bumped each second by `recordingTick`.
    @Published private(set) var now = Date()
    /// True only on the real interactive launch path (not headless / UI test) —
    /// gates recording notifications and first-run onboarding.
    private var interactive = false

    var isRecording: Bool { if case .recording = status { true } else { false } }
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

    init() {
        AppLog.bootstrap()
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
        // Views observe AppState only; forward pipeline / audio-monitor /
        // update-checker change notifications so MainWindowView refreshes
        // when those sub-ObservableObjects publish.
        pipelineObserver = pipeline.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
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
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            Task {
                await LlamaServer.shared.stop()
                await LlamaServer.embedder.stop()
                await LlamaServer.cotyping.stop()
            }
        }
        if handleHeadlessProcessing()
            || handleHeadlessSearch()
            || handleHeadlessRecord()
            || handleHeadlessShotTest()
            || handleHeadlessDigest()
            || handleHeadlessChat() {
            return
        }
        // UI tests render against pre-seeded fixtures, not a real audio/Sparkle
        // session — bail out before any subsystem reaches for the mic, the
        // process list, or the network.
        if Self.isUITesting { return }
        interactive = true
        RecordingNotifier.shared.bootstrap()
        applyTrackingSetting()
        detector.onMeetingStarted = { [weak self] context in
            guard let self else { return }
            switch self.settings.autoRecordMode {
            case .automatic: self.startRecording(context: context, source: "detector")
            case .ask: self.notifyMeetingDetected(context)
            case .manual: break
            }
        }
        detector.onMeetingEnded = { [weak self] in
            self?.stopRecording()
        }
        detector.stopDebounce = settings.stopDebounceSeconds
        detector.calendar = calendar
        detector.calendarEnabled = settings.calendarDetectionEnabled
        detector.requireCalendarForBrowser = settings.requireCalendarForBrowser
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
        // Bring cotyping up if the user left it enabled and the grants are in
        // place; otherwise it parks itself (no taps installed).
        cotyping.applySettings()
    }

    // MARK: - Recording control

    /// Synchronous re-entrancy latch: `status` only flips inside the async
    /// start task, so without this, rapid triggers (detector ticks, double
    /// clicks) all pass the `!isRecording` guard and create empty meetings.
    private var isStartingRecording = false

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

    func startRecording(context: MeetingDetectionContext? = nil, source: String = "ui") {
        guard !isRecording, !isStartingRecording else { return }
        let detectedApp = context?.detectedApp
        let calendarEvent = context?.calendarEvent
        // Don't immediately re-record the same scheduled event after one ended.
        if MeetingMatcher.shouldSuppressRepeat(
            eventID: calendarEvent?.externalID, lastEventID: lastCalendarEventID,
            lastEndedAt: lastCalendarEventEndedAt, now: Date(),
            cooldown: Self.calendarRepeatCooldown) {
            lokalbotv3Log("startRecording suppressed: calendar event \(calendarEvent?.externalID ?? "?") within cooldown")
            return
        }
        isStartingRecording = true
        audioMonitor.isRecordingActive = true
        audioMonitor.accept()
        lokalbotv3Log("startRecording source=\(source) app=\(detectedApp?.name ?? "manual") calendar=\(calendarEvent?.title ?? "none")")
        Task {
            defer { isStartingRecording = false }
            guard await MicRecorder.requestPermission() else {
                lastError = "Microphone permission denied."
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
                startRecordingTick()
                if interactive {
                    RecordingNotifier.shared.recordingStarted(title: meeting.title)
                    prewarmSelectedTranscriptionModel(reason: source)
                }
            } catch {
                lastError = "Could not start recording: \(error.localizedDescription)"
                lokalbotv3Log("startRecording FAILED: \(error.localizedDescription)")
                audioMonitor.isRecordingActive = false
                audioMonitor.reseed()
                // Don't leave a 0-minute husk in the library.
                if let husk = created { storage.deleteMeeting(husk) }
            }
        }
    }

    private func prewarmSelectedTranscriptionModel(reason: String) {
        guard settings.autoTranscribe else { return }
        guard transcriptionPrewarmTask == nil else { return }
        let choice = settings.transcriptionModel
        transcriptionPrewarmTask = Task { [weak self, choice, reason] in
            let started = Date()
            lokalbotv3Log("transcription prewarm start model=\(choice.rawValue) reason=\(reason)")
            do {
                switch choice {
                case .parakeetV3:
                    await ParakeetEngine.shared.setVariant(.v3)
                    try await ParakeetEngine.shared.prepare()
                case .parakeetV2:
                    await ParakeetEngine.shared.setVariant(.v2)
                    try await ParakeetEngine.shared.prepare()
                case .qwenASR17B:
                    try await QwenASREngine.accuracy.prepare()
                case .qwenASR06B:
                    try await QwenASREngine.compact.prepare()
                case .whisperLarge:
                    try await WhisperEngine.shared.prepare()
                case .cohere:
                    try await CohereEngine.shared.prepare()
                case .senseVoice:
                    try await OnnxTranscriptionEngine.senseVoice.prepare()
                case .gigaamRussian:
                    try await OnnxTranscriptionEngine.gigaamRussian.prepare()
                }
                let elapsed = Date().timeIntervalSince(started)
                lokalbotv3Log("transcription prewarm ready model=\(choice.rawValue) elapsed=\(String(format: "%.2fs", elapsed))")
            } catch {
                lokalbotv3Log("transcription prewarm FAILED model=\(choice.rawValue): \(error.localizedDescription)")
            }
            await MainActor.run { self?.transcriptionPrewarmTask = nil }
        }
    }

    /// `AudioSourceMonitor` saw an app newly start producing output. Auto-record
    /// in automatic mode only for high-confidence native meeting output or a
    /// calendar-backed native app; leave broader chat apps as banner/detector
    /// candidates so notification sounds cannot start recordings.
    private func audioMonitorDetected(_ process: AudioProcess) {
        guard !isRecording, !isStartingRecording else { return }
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

    nonisolated static func meetingTitle(for appName: String) -> String {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Meeting" }
        return trimmed.localizedCaseInsensitiveContains("meeting")
            && trimmed.lowercased().hasSuffix("meeting")
            ? trimmed
            : "\(trimmed) meeting"
    }

    func stopRecording(process: Bool = true) {
        guard isRecording, var meeting = currentMeeting else { return }
        micRecorder.stop()
        systemRecorder.stop()
        audioMonitor.isRecordingActive = false
        audioMonitor.reseed()
        stopRecordingTick()
        let endedAt = Date()
        meeting.endedAt = endedAt
        let folder = meeting.folderURL(in: storage)
        meeting.hasSystemTrack = AudioFileInspector.isTranscribableAudio(
            at: folder.appendingPathComponent("system.m4a"))
        // The wall-clock span can outlast the captured audio (e.g. a device
        // disruption truncates the tracks while the session stays live), so
        // store the actual playable length — the longest track — for the UI.
        meeting.recordedDuration = ["mic.m4a", "system.m4a"]
            .compactMap { AudioFileInspector.duration(at: folder.appendingPathComponent($0)) }
            .max()
        try? storage.saveMeta(meeting)
        lastCalendarEventID = meeting.calendarEventID
        lastCalendarEventEndedAt = endedAt
        meetings.insert(meeting, at: 0)
        currentMeeting = nil
        status = .idle
        let willTranscribe = process && settings.autoTranscribe
        if interactive {
            RecordingNotifier.shared.recordingStopped(
                title: meeting.title,
                duration: meeting.recordedDuration ?? endedAt.timeIntervalSince(meeting.startedAt),
                willTranscribe: willTranscribe)
        }
        if willTranscribe {
            pipeline.enqueue(meeting, transcribe: true, summarize: settings.autoSummarize)
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
        startRecording(context: nil, source: "headless")
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
                    meetings: todays, ocr: activityStore.ocrText(on: day), config: settings)
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

    /// `LokalBot --chat "<question>"`: run the meeting chat agent once against
    /// the real engine + tools and print the answer. Test hook for the chat
    /// assistant, same spirit as --search / --digest.
    private func handleHeadlessChat() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--chat"), args.count > flag + 1 else { return false }
        let question = args[flag + 1]
        Task { @MainActor in
            do {
                searchIndex.reindexAll(meetings, storage: storage)
                let engine = try await pipeline.makeTextEngine(settings)
                let tools = MeetingChatTools(
                    meetings: { [weak self] in self?.meetings ?? [] },
                    storage: storage, searchIndex: searchIndex, embeddingIndex: embeddingIndex,
                    settings: { [weak self] in self?.settings ?? AppSettings() })
                let agent = ChatAgent(engine: engine, runner: tools)
                let answer = try await agent.respond(history: [], latest: question) { event in
                    switch event {
                    case .toolStarted(let call):
                        print("LokalBot --chat: tool \(call.name)(\(call.arguments))")
                    case .toolFinished(let name, let summary):
                        print("LokalBot --chat: done \(name) — \(summary)")
                    }
                }
                print("LokalBot --chat: \(answer)")
                await LlamaServer.shared.stop()
                await LlamaServer.embedder.stop()
                exit(0)
            } catch {
                print("LokalBot --chat: FAILED — \(error.localizedDescription)")
                await LlamaServer.shared.stop()
                await LlamaServer.embedder.stop()
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

    private func notifyMeetingDetected(_ context: MeetingDetectionContext) {
        // M1: simple user notification via the menu bar (badge). A richer
        // UNUserNotification with a "Record" action button is a fast follow.
        lastError = nil
        NSSound.beep()
    }
}
