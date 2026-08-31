import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class DictationCoordinator: ObservableObject {

    @Published private(set) var state: State = .idle
    @Published private(set) var isStarting = false
    @Published private(set) var now = Date()
    @Published private(set) var isShortcutMonitoringActive = false
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastComposedText: String?
    @Published private(set) var lastEngine: String?
    @Published var liveTranscript = DictationLiveTranscript()
    @Published var livePreviewStatus = ""
    @Published var isLivePreviewWorking = false
    @Published var isLivePreviewEnabled = false
    @Published private(set) var captureStatus = ""
    @Published private(set) var modelPreparationStatus: String?
    @Published private(set) var modelPreparationProgress: Double?
    @Published private(set) var modelPreparationError: String?

    let storageRoot: URL
    private let settingsProvider: () -> AppSettings
    private let makeTextEngine: () async throws -> TextEngine
    private let screenContextProvider:
        (DictationScreenTarget, [String]) async -> DictationScreenContext?
    private let canStart: () -> Bool
    private let onBusy: () -> Void
    private let onError: (String) -> Void
    private let onMicPermissionDenied: () -> Void
    private let focusSnapshotExecutor: DictationFocusSnapshotExecutor
    let recorder = MicRecorder()
    private let inputMonitor = DictationInputMonitor()
    private let overlay = DictationOverlayController()
    private lazy var inserter = CotypingInserter()
    private var tick: AnyCancellable?
    private var prewarmTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var startTaskGeneration: Int?
    var livePreviewTask: Task<Void, Never>?
    /// Every preview and authoritative pass joins this chain. A cancelled
    /// decoder that does not cooperate immediately therefore remains owned and
    /// cannot overlap the shared model runtime with the next dictation.
    var asrHandoffTask: Task<Void, Never>?
    var livePreviewTaskID = 0
    private var transcribeTask: Task<Void, Never>?
    private var screenContextTask: Task<DictationScreenContext?, Never>?
    private var mediaCleanupTask: Task<Void, Never>?
    private var mediaCleanupGeneration = 0
    private struct PendingTranscriptionRetry {
        var audioURL: URL
        var startedAt: Date
        var source: String
        var generation: Int
    }
    private var pendingTranscriptionRetry: PendingTranscriptionRetry?
    private var activeAudioURL: URL?
    private var pausedMediaSession: MediaPlaybackController.PauseSession?
    private var deliveryTarget: DictationDeliveryTarget?
    private var pendingFinishSource: String?
    var generation = 0

    init(
        storageRoot: URL,
        settingsProvider: @escaping () -> AppSettings,
        makeTextEngine: @escaping () async throws -> TextEngine,
        canStart: @escaping () -> Bool,
        onBusy: @escaping () -> Void,
        onError: @escaping (String) -> Void,
        onMicPermissionDenied: @escaping () -> Void = {},
        focusSnapshotExecutor: DictationFocusSnapshotExecutor = .shared,
        screenContextProvider: @escaping (
            DictationScreenTarget,
            [String]
        ) async -> DictationScreenContext? = { target, excludedApps in
            await DictationScreenContextCapture.shared.capture(
                target: target, excludedApps: excludedApps)
        }
    ) {
        self.storageRoot = storageRoot
        self.settingsProvider = settingsProvider
        self.makeTextEngine = makeTextEngine
        self.screenContextProvider = screenContextProvider
        self.canStart = canStart
        self.onBusy = onBusy
        self.onError = onError
        self.onMicPermissionDenied = onMicPermissionDenied
        self.focusSnapshotExecutor = focusSnapshotExecutor
        inputMonitor.triggerModeProvider = { [weak self] in
            self?.settingsProvider().dictationTriggerMode ?? .pushToTalk
        }
        inputMonitor.shortcutProvider = { .handyDefault }
        inputMonitor.onStart = { [weak self] in self?.start(source: "shortcut") }
        inputMonitor.onStop = { [weak self] in self?.finishRecordingAndTranscribe(source: "shortcut") }
        inputMonitor.onToggle = { [weak self] in self?.toggle(source: "shortcut") }
        Self.sweepOrphanedPreviewFiles(storageRoot: storageRoot)
    }

    var elapsed: TimeInterval {
        switch state {
        case .idle: return 0
        case .recording(let startedAt),
             .transcribing(let startedAt),
             .composing(let startedAt):
            return max(0, now.timeIntervalSince(startedAt))
        }
    }

    var timerLabel: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var menuBarLabel: String {
        switch state {
        case .idle: return ""
        case .recording: return timerLabel
        case .transcribing, .composing: return "..."
        }
    }

    var shouldShowLiveTranscriptPanel: Bool {
        isLivePreviewEnabled && state.isWorking
    }

    var shouldShowModelPreparation: Bool {
        Self.shouldShowModelPreparation(
            state: state,
            hasStatus: modelPreparationStatus != nil,
            hasProgress: modelPreparationProgress != nil,
            hasError: modelPreparationError != nil)
    }

    /// Whether the HUD surfaces model preparation. Preparation begins
    /// synchronously on every recording start, so `.recording` waits for
    /// real download progress (or a failure) — a warm model never flashes
    /// the panel — while `.transcribing` shows any status at all.
    static func shouldShowModelPreparation(
        state: State, hasStatus: Bool, hasProgress: Bool, hasError: Bool
    ) -> Bool {
        switch state {
        case .transcribing:
            return hasStatus || hasError
        case .recording:
            return hasProgress || hasError
        case .idle, .composing:
            return false
        }
    }

    var modelPreparationPresentation: ModelPreparationPresentation {
        if let modelPreparationError {
            return .init(
                state: .failed,
                title: "Dictation model needs attention",
                status: modelPreparationError,
                actionTitle: "Retry")
        }
        return .init(
            state: .preparing,
            title: "Preparing the dictation model",
            status: modelPreparationStatus ?? "Checking the selected speech model…",
            progress: modelPreparationProgress)
    }

    func applySettings() {
        let config = settingsProvider()
        if config.dictationEnabled {
            isShortcutMonitoringActive = inputMonitor.start()
            if !isShortcutMonitoringActive {
                lokalbotLog("dictation shortcut monitor unavailable; Input Monitoring access may be missing")
            }
        } else {
            inputMonitor.stop(releasingHeldShortcut: true)
            isShortcutMonitoringActive = false
        }
        if case .recording = state, let activeAudioURL {
            if config.dictationShowOverlay, config.dictationLivePreview {
                if livePreviewTask == nil {
                    isLivePreviewEnabled = true
                    livePreviewStatus = "Listening"
                    startLivePreviewIfNeeded(
                        audioURL: activeAudioURL,
                        config: config,
                        generation: generation)
                }
            } else {
                cancelLivePreview(reset: true)
            }
        }
        refreshOverlay()
    }

    func stop() {
        inputMonitor.stop()
        isShortcutMonitoringActive = false
        cancel()
        prewarmTask?.cancel()
        prewarmTask = nil
    }

    func toggle(source: String = "ui") {
        if isStarting {
            invalidateStartingSession()
            return
        }
        switch state {
        case .idle:
            start(source: source)
        case .recording:
            finishRecordingAndTranscribe(source: source)
        case .transcribing, .composing:
            cancel()
        }
    }

    func start(source: String = "ui") {
        guard case .idle = state, startTask == nil else { return }
        guard canStart() else {
            onBusy()
            return
        }
        let startedAt = Date()
        generation += 1
        let session = generation
        startTaskGeneration = session
        isStarting = true
        let initialConfig = settingsProvider()
        let outputMode = initialConfig.dictationOutputMode
        let screenTarget = DictationScreenTarget.frontmost()
        let focusCaptureTask = Task { [focusSnapshotExecutor] in
            await focusSnapshotExecutor.capture()
        }
        discardScreenContext()
        if let screenTarget {
            let excludedApps = initialConfig.excludedAppList
            screenContextTask = Task { [screenContextProvider] in
                let capture = await focusCaptureTask.value
                guard DictationScreenPrivacy.allowsCapture(
                        focus: capture, target: screenTarget),
                      !Task.isCancelled else { return nil }
                return await screenContextProvider(screenTarget, excludedApps)
            }
        }
        deliveryTarget = nil
        pendingFinishSource = nil
        captureStatus = ""
        lastTranscript = nil
        lastComposedText = nil
        lastEngine = nil
        resetModelPreparation()
        resetLivePreview()
        refreshOverlay()
        let request = StartRequest(
            startedAt: startedAt,
            session: session,
            source: source,
            outputMode: outputMode,
            focusCaptureTask: focusCaptureTask,
            pendingMediaCleanup: mediaCleanupTask)
        startTask = Task { [weak self] in
            await self?.performStart(request)
        }
    }

    private struct StartRequest {
        let startedAt: Date
        let session: Int
        let source: String
        let outputMode: DictationOutputMode
        let focusCaptureTask: Task<DictationFocusCaptureResult, Never>
        let pendingMediaCleanup: Task<Void, Never>?
    }

    private struct RecordingStartResources {
        let audioURL: URL
        let pausedMedia: MediaPlaybackController.PauseSession
    }

    private func performStart(_ request: StartRequest) async {
        var keepScreenContext = false
        defer { finishStart(request, keepScreenContext: keepScreenContext) }
        guard await MicRecorder.requestPermission() else {
            guard generation == request.session, !Task.isCancelled else { return }
            onMicPermissionDenied()
            return
        }
        let focusCapture = await request.focusCaptureTask.value
        let target = Self.deliveryTarget(for: request.outputMode, capture: focusCapture)
        if let pendingMediaCleanup = request.pendingMediaCleanup {
            await pendingMediaCleanup.value
        }
        guard generation == request.session, !Task.isCancelled else { return }
        deliveryTarget = target
        do {
            let resources = try await recordingStartResources(for: request)
            activateRecording(resources, request: request)
            keepScreenContext = true
        } catch is CancellationError {
            recorder.stop()
            activeAudioURL = nil
        } catch {
            handleStartFailure(error, source: request.source)
        }
    }

    private func finishStart(_ request: StartRequest, keepScreenContext: Bool) {
        request.focusCaptureTask.cancel()
        if !keepScreenContext { discardScreenContext() }
        guard startTaskGeneration == request.session else { return }
        startTask = nil
        startTaskGeneration = nil
        if isStarting {
            isStarting = false
            refreshOverlay()
        }
    }

    private func recordingStartResources(
        for request: StartRequest
    ) async throws -> RecordingStartResources {
        let audioURL = try nextAudioURL(startedAt: request.startedAt)
        let pausedMedia = await MediaPlaybackController.pauseActiveMediaPlayers(
            reason: "dictation")
        do {
            if !pausedMedia.isEmpty {
                try await Task.sleep(for: .milliseconds(250))
            }
            guard generation == request.session, !Task.isCancelled else {
                throw CancellationError()
            }
            try await startRecorder(writingTo: audioURL)
            try Task.checkCancellation()
            guard generation == request.session else { throw CancellationError() }
            return .init(audioURL: audioURL, pausedMedia: pausedMedia)
        } catch {
            let reason = error is CancellationError
                ? "cancelled dictation start" : "failed dictation start"
            await MediaPlaybackController.resume(pausedMedia, reason: reason)
            recorder.stop()
            try? FileManager.default.removeItem(at: audioURL)
            throw error
        }
    }

    private func activateRecording(
        _ resources: RecordingStartResources,
        request: StartRequest
    ) {
        pausedMediaSession = resources.pausedMedia
        activeAudioURL = resources.audioURL
        state = .recording(startedAt: request.startedAt)
        startTick()
        let config = settingsProvider()
        isLivePreviewEnabled = config.dictationShowOverlay && config.dictationLivePreview
        livePreviewStatus = isLivePreviewEnabled ? "Listening" : ""
        refreshOverlay()
        prewarmSelectedModel(reason: request.source)
        startLivePreviewIfNeeded(
            audioURL: resources.audioURL,
            config: config,
            generation: request.session)
        lokalbotLog("dictation recording started source=\(request.source)")
        finishPendingStartIfNeeded()
    }

    private func finishPendingStartIfNeeded() {
        guard let source = pendingFinishSource else { return }
        pendingFinishSource = nil
        isStarting = false
        finishRecordingAndTranscribe(source: source)
    }

    private func handleStartFailure(_ error: Error, source: String) {
        onError("Could not start dictation: \(error.localizedDescription)")
        lokalbotLog("dictation start FAILED source=\(source): \(error.localizedDescription)")
        activeAudioURL = nil
        state = .idle
        stopTick()
        resetLivePreview()
        refreshOverlay()
    }

    func finishRecordingAndTranscribe(source: String = "ui") {
        if isStarting {
            // Push-to-talk key-up can arrive while permission, focus, or media
            // setup is still finishing. Remember the release instead of
            // cancelling the start and silently dropping the invocation.
            pendingFinishSource = source
            return
        }
        guard case .recording(let startedAt) = state, let audioURL = activeAudioURL else { return }
        let captureDuration = recorder.captureHealth().duration
        cancelLivePreview(reset: false)
        let mediaSession = pausedMediaSession
        pausedMediaSession = nil
        recorder.stop()
        activeAudioURL = nil
        stopTick()
        state = .transcribing(startedAt: startedAt)
        lokalbotLog(
            "dictation recording stopped source=\(source) duration="
                + String(format: "%.2f", captureDuration))
        if isLivePreviewEnabled {
            livePreviewStatus = "Finalizing"
        }
        refreshOverlay()
        generation += 1
        let session = generation
        let mediaCleanup = mediaSession.map {
            scheduleMediaResume($0, reason: "dictation capture finished")
        }
        transcribeTask?.cancel()
        transcribeTask = Task { [weak self] in
            if let mediaCleanup { await mediaCleanup.value }
            guard !Task.isCancelled else { return }
            await self?.transcribeAndDeliver(audioURL: audioURL, startedAt: startedAt,
                                             source: source, generation: session)
        }
    }

    func cancel() {
        if isStarting {
            invalidateStartingSession()
            prewarmTask?.cancel()
            prewarmTask = nil
            return
        }
        generation += 1
        transcribeTask?.cancel()
        transcribeTask = nil
        prewarmTask?.cancel()
        prewarmTask = nil
        discardPendingTranscriptionRetry()
        resetModelPreparation()
        discardScreenContext()
        cancelLivePreview(reset: true)
        if case .recording = state {
            recorder.stop()
        }
        if let activeAudioURL {
            try? FileManager.default.removeItem(at: activeAudioURL)
        }
        activeAudioURL = nil
        state = .idle
        stopTick()
        deliveryTarget = nil
        pendingFinishSource = nil
        captureStatus = ""
        let mediaSession = pausedMediaSession
        pausedMediaSession = nil
        refreshOverlay()
        if let mediaSession {
            scheduleMediaResume(mediaSession, reason: "cancelled dictation")
        }
        lokalbotLog("dictation cancelled")
    }

    private func transcribeAndDeliver(
        audioURL: URL,
        startedAt: Date,
        source: String,
        generation session: Int
    ) async {
        var preserveAudioForRetry = false
        defer {
            if !preserveAudioForRetry, !settingsProvider().dictationRetainAudio {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
        let config = settingsProvider()
        let choice = config.transcriptionModel
        let engine = config.transcriptionEngine()
        switch await prepareTranscriptionEngine(
            engine,
            choice: choice,
            audioURL: audioURL,
            startedAt: startedAt,
            source: source,
            session: session
        ) {
        case .ready:
            break
        case .cancelled:
            return
        case .retry:
            preserveAudioForRetry = true
            return
        }
        do {
            guard let result = try await composeDictation(
                audioURL: audioURL,
                startedAt: startedAt,
                config: config,
                session: session
            ) else { return }
            guard await deliver(result.text, config: config, session: session) else { return }
            complete()
            lokalbotLog(
                "dictation composed source=\(source) chars=\(result.text.count) "
                    + "asr=\(result.transcriptionEngine) llm=\(result.textEngine) "
                    + "screenChars=\(result.screenCharacterCount)")
        } catch is CancellationError {
            guard generation == session else { return }
            complete()
        } catch {
            guard generation == session else { return }
            let prefix: String
            if case .composing = state {
                prefix = "Could not compose dictation"
            } else {
                prefix = "Dictation failed"
            }
            completeWithMessage("\(prefix): \(error.localizedDescription)")
        }
    }

    private enum ModelPreparationOutcome {
        case ready
        case cancelled
        case retry
    }

    private struct ComposedDictation {
        let text: String
        let transcriptionEngine: String
        let textEngine: String
        let screenCharacterCount: Int
    }

    private func prepareTranscriptionEngine(
        _ engine: any TranscriptionEngine,
        choice: TranscriptionModelChoice,
        audioURL: URL,
        startedAt: Date,
        source: String,
        session: Int
    ) async -> ModelPreparationOutcome {
        beginModelPreparation()
        do {
            try await engine.prepare { [weak self] update in
                self?.receiveModelPreparation(update, generation: session)
            }
            try Task.checkCancellation()
            guard generation == session else { return .cancelled }
            resetModelPreparation()
            return .ready
        } catch is CancellationError {
            guard generation == session else { return .cancelled }
            complete()
            return .cancelled
        } catch {
            guard generation == session else { return .cancelled }
            parkTranscriptionRetry(
                audioURL: audioURL,
                startedAt: startedAt,
                source: source,
                session: session,
                choice: choice,
                error: error)
            return .retry
        }
    }

    private func parkTranscriptionRetry(
        audioURL: URL,
        startedAt: Date,
        source: String,
        session: Int,
        choice: TranscriptionModelChoice,
        error: Error
    ) {
        pendingTranscriptionRetry = .init(
            audioURL: audioURL,
            startedAt: startedAt,
            source: source,
            generation: session)
        modelPreparationStatus = nil
        modelPreparationProgress = nil
        modelPreparationError = Self.modelPreparationFailureMessage
        onError(
            "Dictation is paused while its speech model needs attention. "
                + "Choose Retry in the dictation panel.")
        lokalbotLog(
            "dictation model preparation FAILED model=\(choice.rawValue): "
                + error.localizedDescription)
        refreshOverlay()
    }

    private func composeDictation(
        audioURL: URL,
        startedAt: Date,
        config: AppSettings,
        session: Int
    ) async throws -> ComposedDictation? {
        let transcript = try await transcribeSerialized(audioURL, config: config)
        try ensureActive(session)
        let spokenText = Transcript.normalizedText(
            transcript.segments.map(\.displayText).joined(separator: " "))
        guard !spokenText.isEmpty else {
            completeWithMessage("No speech detected.")
            return nil
        }
        beginComposing(spokenText, startedAt: startedAt)
        let screenContext = await takeScreenContext()
        try ensureActive(session)
        let textEngine = try await makeTextEngine()
        let text = try await generateComposedText(
            spokenText: spokenText,
            screenContext: screenContext,
            config: config,
            engine: textEngine)
        try ensureActive(session)
        lastComposedText = text
        lastEngine = "\(transcript.engine) → \(textEngine.displayName)"
        return .init(
            text: text,
            transcriptionEngine: transcript.engine,
            textEngine: textEngine.displayName,
            screenCharacterCount: screenContext?.visibleText.count ?? 0)
    }

    private func ensureActive(_ session: Int) throws {
        try Task.checkCancellation()
        guard generation == session else { throw CancellationError() }
    }

    private func beginComposing(_ spokenText: String, startedAt: Date) {
        lastTranscript = spokenText
        if isLivePreviewEnabled {
            liveTranscript = .init(committed: spokenText, tentative: "")
            livePreviewStatus = "Composing"
        }
        state = .composing(startedAt: startedAt)
        refreshOverlay()
    }

    private func takeScreenContext() async -> DictationScreenContext? {
        let task = screenContextTask
        screenContextTask = nil
        return await task?.value
    }

    private func generateComposedText(
        spokenText: String,
        screenContext: DictationScreenContext?,
        config: AppSettings,
        engine: TextEngine
    ) async throws -> String {
        let prompt = DictationComposePrompt.userPrompt(
            spokenText: spokenText,
            context: screenContext,
            profile: DictationComposeProfile(
                personalization: config.cotypingPersonalization))
        let output = try await engine.generate(
            system: DictationComposePrompt.system,
            prompt: prompt,
            context: [])
        let text = DictationComposePrompt.normalizedOutput(output)
        guard !text.isEmpty else { throw DictationComposeError.emptyOutput }
        return text
    }

    private func deliver(
        _ text: String,
        config: AppSettings,
        session: Int
    ) async -> Bool {
        switch await deliver(
            text,
            mode: config.dictationOutputMode,
            generation: session
        ) {
        case .inserted, .copied:
            return true
        case .focusChanged:
            onError(
                "Dictation finished after focus moved, so the text was copied "
                    + "to the clipboard instead of being inserted into another app.")
            return true
        case .failed:
            onError(
                "Dictation finished, but LokalBot could not insert the text. "
                    + "It was copied to the clipboard.")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return true
        case .cancelled:
            return false
        }
    }

    private enum DeliveryResult {
        case inserted
        case copied
        case focusChanged
        case failed
        case cancelled
    }

    private func deliver(
        _ text: String,
        mode: DictationOutputMode,
        generation session: Int
    ) async -> DeliveryResult {
        guard !Task.isCancelled, generation == session else { return .cancelled }
        switch mode {
        case .pasteIntoFocusedApp:
            let targetMatches = await deliveryTargetMatchesCurrentFocus()
            guard !Task.isCancelled, generation == session else { return .cancelled }
            guard targetMatches else {
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(text, forType: .string)
                    ? .focusChanged : .failed
            }
            guard !Task.isCancelled, generation == session else { return .cancelled }
            return inserter.insertViaPaste(text) || inserter.insert(text) ? .inserted : .failed
        case .copyToClipboard:
            guard !Task.isCancelled, generation == session else { return .cancelled }
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string) ? .copied : .failed
        }
    }

    private func complete() {
        pendingTranscriptionRetry = nil
        resetModelPreparation()
        discardScreenContext()
        state = .idle
        stopTick()
        resetLivePreview()
        captureStatus = ""
        deliveryTarget = nil
        refreshOverlay()
    }

    nonisolated private static func deliveryTarget(
        for mode: DictationOutputMode,
        capture: DictationFocusCaptureResult
    ) -> DictationDeliveryTarget? {
        guard mode == .pasteIntoFocusedApp else { return nil }
        guard !capture.timedOut, let snapshot = capture.snapshot else { return nil }
        return DictationDeliveryTarget.captured(from: snapshot)
    }

    private func deliveryTargetMatchesCurrentFocus() async -> Bool {
        guard let deliveryTarget else { return false }
        let capture = await focusSnapshotExecutor.capture()
        guard !capture.timedOut, let snapshot = capture.snapshot else { return false }
        return deliveryTarget.matches(snapshot)
    }

    private func invalidateStartingSession() {
        generation += 1
        // Do not cancel an in-flight media pause: it is bounded, and allowing
        // it to return gives that task the exact resume token it needs. The
        // generation guard prevents the recorder from starting afterward. Keep
        // the task retained until that pause-and-resume cleanup finishes so a
        // new start cannot race ahead of its late media restoration.
        isStarting = false
        state = .idle
        stopTick()
        deliveryTarget = nil
        pendingFinishSource = nil
        captureStatus = ""
        discardScreenContext()
        resetLivePreview()
        refreshOverlay()
        lokalbotLog("dictation start cancelled before capture")
    }

    private func discardScreenContext() {
        screenContextTask?.cancel()
        screenContextTask = nil
    }

    @discardableResult
    private func scheduleMediaResume(
        _ session: MediaPlaybackController.PauseSession,
        reason: String
    ) -> Task<Void, Never> {
        mediaCleanupGeneration += 1
        let cleanupGeneration = mediaCleanupGeneration
        let precedingCleanup = mediaCleanupTask
        let task = Task { [weak self] in
            if let precedingCleanup { await precedingCleanup.value }
            await MediaPlaybackController.resume(session, reason: reason)
            guard let self, self.mediaCleanupGeneration == cleanupGeneration else { return }
            self.mediaCleanupTask = nil
        }
        mediaCleanupTask = task
        return task
    }

    private func completeWithMessage(_ message: String) {
        lokalbotLog("dictation ended without delivery: \(message)")
        onError(message)
        complete()
    }

    func retryModelPreparation() {
        modelPreparationError = nil
        if let pending = pendingTranscriptionRetry {
            pendingTranscriptionRetry = nil
            beginModelPreparation()
            transcribeTask?.cancel()
            transcribeTask = Task { [weak self] in
                await self?.transcribeAndDeliver(
                    audioURL: pending.audioURL,
                    startedAt: pending.startedAt,
                    source: pending.source,
                    generation: pending.generation)
            }
        } else {
            prewarmSelectedModel(reason: "retry")
        }
        refreshOverlay()
    }

    static func transcribe(_ audioURL: URL, config: AppSettings) async throws -> Transcript {
        guard let duration = AudioFileInspector.duration(at: audioURL),
              duration >= AudioFileInspector.minimumTranscribableDuration else {
            throw DictationError.noAudio
        }
        if let speech = await SpeechActivity.shared.speechSeconds(in: audioURL), speech < 0.5 {
            throw DictationError.noSpeech
        }
        return try await config.transcriptionEngine().transcribe(
            audio: audioURL,
            language: config.transcriptionLanguage.code)
    }

    private func startRecorder(writingTo audioURL: URL) async throws {
        recorder.stop()
        try? FileManager.default.removeItem(at: audioURL)
        do {
            try recorder.start(writingTo: audioURL)
        } catch {
            lokalbotLog("dictation recorder start retrying after: \(error.localizedDescription)")
            recorder.stop()
            try? FileManager.default.removeItem(at: audioURL)
            try await Task.sleep(for: .milliseconds(150))
            try recorder.start(writingTo: audioURL)
        }
    }

    private func prewarmSelectedModel(reason: String) {
        prewarmTask?.cancel()
        let config = settingsProvider()
        let choice = config.transcriptionModel
        let engine = config.transcriptionEngine()
        let session = generation
        beginModelPreparation()
        prewarmTask = Task { [weak self, choice, engine, reason, session] in
            guard let self else { return }
            do {
                try await engine.prepare { [weak self] update in
                    self?.receiveModelPreparation(update, generation: session)
                }
                guard self.generation == session, !Task.isCancelled else { return }
                self.resetModelPreparation()
                lokalbotLog("dictation prewarm ready model=\(choice.rawValue) reason=\(reason)")
            } catch is CancellationError {
            } catch {
                guard self.generation == session, !Task.isCancelled else { return }
                self.modelPreparationStatus = nil
                self.modelPreparationProgress = nil
                self.modelPreparationError = Self.modelPreparationFailureMessage
                self.onError(
                    "Could not prepare the dictation model. It will retry when recording ends.")
                self.refreshOverlay()
                lokalbotLog("dictation prewarm FAILED model=\(choice.rawValue): \(error.localizedDescription)")
            }
        }
    }

    private static let modelPreparationFailureMessage =
        "Check your connection and free disk space, then try again."

    private func beginModelPreparation() {
        modelPreparationError = nil
        modelPreparationProgress = nil
        modelPreparationStatus = "Checking the selected speech model…"
        refreshOverlay()
    }

    private func receiveModelPreparation(
        _ update: ModelPreparationUpdate,
        generation session: Int
    ) {
        guard generation == session else { return }
        if update.status == "Ready" {
            resetModelPreparation()
            return
        }
        modelPreparationError = nil
        modelPreparationProgress = update.fractionCompleted
        modelPreparationStatus = update.status
        refreshOverlay()
    }

    private func resetModelPreparation() {
        modelPreparationStatus = nil
        modelPreparationProgress = nil
        modelPreparationError = nil
    }

    private func discardPendingTranscriptionRetry() {
        guard let pending = pendingTranscriptionRetry else { return }
        pendingTranscriptionRetry = nil
        if !settingsProvider().dictationRetainAudio {
            try? FileManager.default.removeItem(at: pending.audioURL)
        }
    }

    private func nextAudioURL(startedAt: Date) throws -> URL {
        let dir = storageRoot.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let seconds = Int(startedAt.timeIntervalSince1970)
        return dir.appendingPathComponent("dictation-\(seconds)-\(UUID().uuidString).caf")
    }

    private func startTick() {
        now = Date()
        tick = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                self?.now = date
                self?.refreshCaptureHealth()
            }
    }

    private func stopTick() {
        tick?.cancel()
        tick = nil
    }

    private func refreshCaptureHealth() {
        guard case .recording = state else {
            captureStatus = ""
            return
        }
        let health = recorder.captureHealth()
        switch health.recoveryState {
        case .healthy:
            if health.isEngineRunning {
                captureStatus = ""
            } else {
                captureStatus = "Reconnecting microphone"
                do {
                    try recorder.restartCapture()
                } catch {
                    lokalbotLog(
                        "dictation microphone restart retrying after: "
                            + error.localizedDescription)
                }
            }
        case .recovering(let attempt):
            captureStatus = attempt == 0
                ? "Reconnecting microphone"
                : "Reconnecting microphone (\(attempt)/\(MicRecorder.maximumReconfigurationAttempts))"
        case .degraded(let errorDescription):
            captureStatus = ""
            lokalbotLog("dictation microphone recovery FAILED: \(errorDescription)")
            cancel()
            onError("Dictation stopped because the microphone could not recover: \(errorDescription)")
        }
    }

    func refreshOverlay() {
        overlay.update(for: self, visible: settingsProvider().dictationShowOverlay)
    }
}
