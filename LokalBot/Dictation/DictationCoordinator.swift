import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class DictationCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case transcribing(startedAt: Date)

        var isRecording: Bool {
            if case .recording = self { true } else { false }
        }

        var isWorking: Bool {
            switch self {
            case .idle: false
            case .recording, .transcribing: true
            }
        }

        var label: String {
            switch self {
            case .idle: "Ready"
            case .recording: "Recording"
            case .transcribing: "Transcribing"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isStarting = false
    @Published private(set) var now = Date()
    @Published private(set) var isShortcutMonitoringActive = false
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastEngine: String?
    @Published private(set) var liveTranscript = DictationLiveTranscript()
    @Published private(set) var livePreviewStatus = ""
    @Published private(set) var isLivePreviewWorking = false
    @Published private(set) var isLivePreviewEnabled = false

    private let storageRoot: URL
    private let settingsProvider: () -> AppSettings
    private let canStart: () -> Bool
    private let onBusy: () -> Void
    private let onError: (String) -> Void
    private let focusSnapshotExecutor: DictationFocusSnapshotExecutor
    private let recorder = MicRecorder()
    private let inputMonitor = DictationInputMonitor()
    private let overlay = DictationOverlayController()
    private lazy var inserter = CotypingInserter()
    private var tick: AnyCancellable?
    private var prewarmTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var startTaskGeneration: Int?
    private var livePreviewTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    private var mediaCleanupTask: Task<Void, Never>?
    private var mediaCleanupGeneration = 0
    private var activeAudioURL: URL?
    private var pausedMediaSession: MediaPlaybackController.PauseSession?
    private var deliveryTarget: DictationDeliveryTarget?
    private var generation = 0

    init(
        storageRoot: URL,
        settingsProvider: @escaping () -> AppSettings,
        canStart: @escaping () -> Bool,
        onBusy: @escaping () -> Void,
        onError: @escaping (String) -> Void,
        focusSnapshotExecutor: DictationFocusSnapshotExecutor = .shared
    ) {
        self.storageRoot = storageRoot
        self.settingsProvider = settingsProvider
        self.canStart = canStart
        self.onBusy = onBusy
        self.onError = onError
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
        case .recording(let startedAt), .transcribing(let startedAt):
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
        case .transcribing: return "..."
        }
    }

    var shouldShowLiveTranscriptPanel: Bool {
        isLivePreviewEnabled && state.isWorking
    }

    func applySettings() {
        let config = settingsProvider()
        if config.dictationEnabled {
            isShortcutMonitoringActive = inputMonitor.start()
        } else {
            inputMonitor.stop()
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
                _ = cancelLivePreview(reset: true)
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
        case .transcribing:
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
        let outputMode = settingsProvider().dictationOutputMode
        let deliveryTargetTask = Task { [focusSnapshotExecutor] in
            await Self.captureDeliveryTarget(
                for: outputMode,
                using: focusSnapshotExecutor)
        }
        deliveryTarget = nil
        resetLivePreview()
        refreshOverlay()
        let pendingMediaCleanup = mediaCleanupTask
        startTask = Task { [weak self] in
            guard let self else { return }
            defer {
                deliveryTargetTask.cancel()
                if self.startTaskGeneration == session {
                    self.startTask = nil
                    self.startTaskGeneration = nil
                    if self.isStarting {
                        self.isStarting = false
                        self.refreshOverlay()
                    }
                }
            }
            guard await MicRecorder.requestPermission() else {
                guard self.generation == session, !Task.isCancelled else { return }
                self.onError("Microphone permission denied.")
                return
            }
            let capturedDeliveryTarget = await deliveryTargetTask.value
            // An earlier cancel may still be restoring the exact players it
            // paused. Finish that bounded transition before taking a new media
            // snapshot, otherwise its late resume could interrupt this capture.
            if let pendingMediaCleanup { await pendingMediaCleanup.value }
            guard self.generation == session, !Task.isCancelled else { return }
            self.deliveryTarget = capturedDeliveryTarget
            var localMediaSession: MediaPlaybackController.PauseSession?
            do {
                let audioURL = try self.nextAudioURL(startedAt: startedAt)
                let pausedMedia = await MediaPlaybackController.pauseActiveMediaPlayers(
                    reason: "dictation")
                localMediaSession = pausedMedia
                if !pausedMedia.isEmpty {
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard self.generation == session, !Task.isCancelled else {
                    await MediaPlaybackController.resume(pausedMedia, reason: "cancelled dictation start")
                    return
                }
                try await self.startRecorder(writingTo: audioURL)
                try Task.checkCancellation()
                guard self.generation == session else { throw CancellationError() }
                self.pausedMediaSession = pausedMedia
                localMediaSession = nil
                self.activeAudioURL = audioURL
                self.state = .recording(startedAt: startedAt)
                self.startTick()
                let config = self.settingsProvider()
                self.isLivePreviewEnabled = config.dictationShowOverlay && config.dictationLivePreview
                self.livePreviewStatus = self.isLivePreviewEnabled ? "Listening" : ""
                self.refreshOverlay()
                self.prewarmSelectedModel(reason: source)
                self.startLivePreviewIfNeeded(audioURL: audioURL, config: config, generation: session)
                lokalbotLog("dictation recording started source=\(source)")
            } catch is CancellationError {
                if let localMediaSession {
                    await MediaPlaybackController.resume(
                        localMediaSession, reason: "cancelled dictation start")
                } else {
                    await self.resumePausedMedia(reason: "cancelled dictation start")
                }
                self.recorder.stop()
                self.activeAudioURL = nil
            } catch {
                if let localMediaSession {
                    await MediaPlaybackController.resume(
                        localMediaSession, reason: "failed dictation start")
                } else {
                    await self.resumePausedMedia(reason: "failed dictation start")
                }
                self.onError("Could not start dictation: \(error.localizedDescription)")
                self.activeAudioURL = nil
                self.state = .idle
                self.stopTick()
                self.resetLivePreview()
                self.refreshOverlay()
            }
        }
    }

    func finishRecordingAndTranscribe(source: String = "ui") {
        if isStarting {
            invalidateStartingSession()
            return
        }
        guard case .recording(let startedAt) = state, let audioURL = activeAudioURL else { return }
        let previewTask = cancelLivePreview(reset: false)
        let mediaSession = pausedMediaSession
        pausedMediaSession = nil
        recorder.stop()
        activeAudioURL = nil
        stopTick()
        state = .transcribing(startedAt: startedAt)
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
            if let previewTask { await previewTask.value }
            guard !Task.isCancelled else { return }
            await self?.transcribeAndDeliver(audioURL: audioURL, startedAt: startedAt,
                                             source: source, generation: session)
        }
    }

    func cancel() {
        if startTask != nil {
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
        _ = cancelLivePreview(reset: true)
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
        defer {
            if !settingsProvider().dictationRetainAudio {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
        do {
            let config = settingsProvider()
            let transcript = try await Self.transcribe(audioURL, config: config)
            try Task.checkCancellation()
            guard generation == session else { return }

            let text = Transcript.normalizedText(
                transcript.segments.map(\.displayText).joined(separator: " "))
            guard !text.isEmpty else {
                completeWithMessage("No speech detected.")
                return
            }

            lastTranscript = text
            lastEngine = transcript.engine
            switch await deliver(text, mode: config.dictationOutputMode) {
            case .inserted, .copied:
                break
            case .focusChanged:
                onError("Dictation finished after focus moved, so the text was copied to the clipboard instead of being inserted into another app.")
            case .failed:
                onError("Dictation finished, but LokalBot could not insert the text. It was copied to the clipboard.")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            complete()
            lokalbotLog("dictation delivered source=\(source) chars=\(text.count) engine=\(transcript.engine)")
        } catch is CancellationError {
            guard generation == session else { return }
            complete()
        } catch {
            guard generation == session else { return }
            completeWithMessage("Dictation failed: \(error.localizedDescription)")
        }
    }

    private enum DeliveryResult {
        case inserted
        case copied
        case focusChanged
        case failed
    }

    private func deliver(_ text: String, mode: DictationOutputMode) async -> DeliveryResult {
        switch mode {
        case .pasteIntoFocusedApp:
            guard await deliveryTargetMatchesCurrentFocus() else {
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(text, forType: .string)
                    ? .focusChanged : .failed
            }
            return inserter.insertViaPaste(text) || inserter.insert(text) ? .inserted : .failed
        case .copyToClipboard:
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string) ? .copied : .failed
        }
    }

    private func complete() {
        state = .idle
        stopTick()
        resetLivePreview()
        deliveryTarget = nil
        refreshOverlay()
    }

    nonisolated private static func captureDeliveryTarget(
        for mode: DictationOutputMode,
        using executor: DictationFocusSnapshotExecutor
    ) async -> DictationDeliveryTarget? {
        guard mode == .pasteIntoFocusedApp else { return nil }
        let capture = await executor.capture()
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
        resetLivePreview()
        refreshOverlay()
        lokalbotLog("dictation start cancelled before capture")
    }

    private func resumePausedMedia(reason: String) async {
        guard let pausedMediaSession else { return }
        self.pausedMediaSession = nil
        await MediaPlaybackController.resume(pausedMediaSession, reason: reason)
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
        onError(message)
        complete()
    }

    private static func transcribe(_ audioURL: URL, config: AppSettings) async throws -> Transcript {
        guard let duration = AudioFileInspector.duration(at: audioURL),
              duration >= AudioFileInspector.minimumTranscribableDuration else {
            throw DictationError.noAudio
        }
        if let speech = await SpeechActivity.shared.speechSeconds(in: audioURL), speech < 0.5 {
            throw DictationError.noSpeech
        }
        return try await config.transcriptionModel.engine.transcribe(
            audio: audioURL,
            language: config.transcriptionLanguage.code)
    }

    private func startLivePreviewIfNeeded(
        audioURL: URL,
        config: AppSettings,
        generation session: Int
    ) {
        guard config.dictationShowOverlay, config.dictationLivePreview else { return }
        livePreviewTask?.cancel()
        livePreviewTask = Task { [weak self] in
            await self?.runLivePreviewLoop(
                audioURL: audioURL,
                config: config,
                generation: session)
        }
    }

    private func runLivePreviewLoop(
        audioURL: URL,
        config: AppSettings,
        generation session: Int
    ) async {
        defer {
            if generation == session {
                livePreviewTask = nil
                isLivePreviewWorking = false
            }
        }
        var lastPreviewedDuration: TimeInterval = 0
        var accumulatedPreviewText = ""
        do {
            try await Task.sleep(for: .milliseconds(1_200))
            while !Task.isCancelled {
                guard generation == session, state.isRecording else { return }
                let duration = recorder.captureHealth().duration
                let minimumAdvance = duration < 10 ? 1.25 : 2.0
                guard duration >= 1.25,
                      duration - lastPreviewedDuration >= minimumAdvance else {
                    try await Task.sleep(for: .milliseconds(450))
                    continue
                }

                do {
                    let window = try await Self.makeIncrementalLivePreviewWindow(
                        from: audioURL,
                        storageRoot: storageRoot,
                        previousEnd: lastPreviewedDuration)
                    defer { try? FileManager.default.removeItem(at: window.url) }
                    try Task.checkCancellation()
                    guard generation == session, state.isRecording else { return }

                    isLivePreviewWorking = true
                    livePreviewStatus = liveTranscript.isEmpty ? "Listening" : "Updating"
                    refreshOverlay()

                    do {
                        let transcript = try await Self.transcribe(window.url, config: config)
                        try Task.checkCancellation()
                        guard generation == session else { return }
                        let text = Transcript.normalizedText(
                            transcript.segments.map(\.displayText).joined(separator: " "))
                        lastPreviewedDuration = window.endTime
                        if !text.isEmpty {
                            // While the overlap still reaches the recording's
                            // beginning, this window is the complete prefix and
                            // can replace the earlier preview outright.
                            accumulatedPreviewText = window.startTime == 0
                                ? text
                                : DictationPreviewTextStitcher.stitch(
                                    previous: accumulatedPreviewText,
                                    incoming: text)
                            liveTranscript = DictationLiveTranscript.preview(
                                from: accumulatedPreviewText)
                            livePreviewStatus = "Live"
                            refreshOverlay()
                        }
                    } catch DictationError.noAudio {
                        // A valid snapshot can still be a fraction shorter than
                        // the recorder's health counter. Advance past that tiny
                        // silent/short window rather than retrying it forever.
                        lastPreviewedDuration = window.endTime
                    } catch DictationError.noSpeech {
                        lastPreviewedDuration = window.endTime
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if generation == session {
                        livePreviewStatus = liveTranscript.isEmpty ? "Listening" : "Live"
                        lokalbotLog("dictation live preview skipped: \(error.localizedDescription)")
                    }
                }
                guard generation == session, state.isRecording else { return }
                isLivePreviewWorking = false
                refreshOverlay()
                try await Task.sleep(
                    for: .milliseconds(Int(Self.livePreviewInterval(after: duration) * 1_000)))
            }
        } catch is CancellationError {
            isLivePreviewWorking = false
        } catch {
            isLivePreviewWorking = false
            lokalbotLog("dictation live preview stopped: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func cancelLivePreview(reset: Bool) -> Task<Void, Never>? {
        let task = livePreviewTask
        task?.cancel()
        livePreviewTask = nil
        isLivePreviewWorking = false
        if reset {
            resetLivePreview()
        }
        return task
    }

    private func resetLivePreview() {
        liveTranscript = DictationLiveTranscript()
        livePreviewStatus = ""
        isLivePreviewWorking = false
        isLivePreviewEnabled = false
    }

    private static func livePreviewInterval(after duration: TimeInterval) -> TimeInterval {
        min(4.0, max(1.4, duration / 8.0))
    }

    nonisolated static let previewScratchDirectoryName = "dictation-previews"

    nonisolated static func sweepOrphanedPreviewFiles(storageRoot: URL) {
        try? FileManager.default.removeItem(at: storageRoot.appendingPathComponent(
            previewScratchDirectoryName, isDirectory: true))
    }

    private struct IncrementalLivePreviewWindow: Sendable {
        let url: URL
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    /// Opens the append-safe CAF at its current length and materializes only the
    /// unprocessed suffix plus a short overlap. This keeps preview I/O bounded
    /// as dictation grows instead of copying the full recording on every pass.
    private static func makeIncrementalLivePreviewWindow(
        from audioURL: URL,
        storageRoot: URL,
        previousEnd: TimeInterval
    ) async throws -> IncrementalLivePreviewWindow {
        try await Task.detached(priority: .userInitiated) {
            try makeIncrementalLivePreviewWindowSynchronously(
                from: audioURL,
                storageRoot: storageRoot,
                previousEnd: previousEnd)
        }.value
    }

    private nonisolated static func makeIncrementalLivePreviewWindowSynchronously(
        from audioURL: URL,
        storageRoot: URL,
        previousEnd: TimeInterval
    ) throws -> IncrementalLivePreviewWindow {
        let reader = try AVAudioFile(forReading: audioURL)
        let format = reader.processingFormat
        guard format.sampleRate > 0 else { throw DictationError.noAudio }
        let currentEnd = Double(reader.length) / format.sampleRate
        guard let range = DictationPreviewWindowPlanner.range(
            previousEnd: previousEnd,
            currentEnd: currentEnd) else {
            throw DictationError.noAudio
        }

        let startFrame = min(
            AVAudioFramePosition(range.start * format.sampleRate),
            reader.length)
        let endFrame = reader.length
        guard endFrame > startFrame else { throw DictationError.noAudio }

        let scratch = storageRoot.appendingPathComponent(
            previewScratchDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let ext = audioURL.pathExtension.isEmpty ? "caf" : audioURL.pathExtension
        let windowURL = scratch.appendingPathComponent(
            "dictation-live-window-\(UUID().uuidString).\(ext)")
        var keepWindow = false
        defer {
            if !keepWindow { try? FileManager.default.removeItem(at: windowURL) }
        }

        reader.framePosition = startFrame
        do {
            let writer = try AVAudioFile(
                forWriting: windowURL,
                settings: reader.fileFormat.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved)
            let bufferCapacity: AVAudioFrameCount = 16_384
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: bufferCapacity) else {
                throw DictationError.noAudio
            }
            var remaining = endFrame - startFrame
            var written: AVAudioFramePosition = 0
            while remaining > 0 {
                let requested = AVAudioFrameCount(min(
                    remaining,
                    AVAudioFramePosition(bufferCapacity)))
                try reader.read(into: buffer, frameCount: requested)
                guard buffer.frameLength > 0 else { break }
                try writer.write(from: buffer)
                let count = AVAudioFramePosition(buffer.frameLength)
                remaining -= count
                written += count
            }
            guard written > 0 else { throw DictationError.noAudio }
        }

        keepWindow = true
        return .init(url: windowURL, startTime: range.start, endTime: range.end)
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
        let choice = settingsProvider().transcriptionModel
        prewarmTask = Task { [choice, reason] in
            do {
                try await choice.engine.prepare()
                lokalbotLog("dictation prewarm ready model=\(choice.rawValue) reason=\(reason)")
            } catch {
                lokalbotLog("dictation prewarm FAILED model=\(choice.rawValue): \(error.localizedDescription)")
            }
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
            .sink { [weak self] date in self?.now = date }
    }

    private func stopTick() {
        tick?.cancel()
        tick = nil
    }

    private func refreshOverlay() {
        overlay.update(for: self, visible: settingsProvider().dictationShowOverlay)
    }
}

private enum DictationError: LocalizedError {
    case noAudio
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .noAudio: "Recording was too short to transcribe."
        case .noSpeech: "No speech detected."
        }
    }
}
