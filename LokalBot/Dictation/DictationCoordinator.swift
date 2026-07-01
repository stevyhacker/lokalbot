import AppKit
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
    private let recorder = MicRecorder()
    private let inputMonitor = DictationInputMonitor()
    private let overlay = DictationOverlayController()
    private lazy var inserter = CotypingInserter()
    private var tick: AnyCancellable?
    private var prewarmTask: Task<Void, Never>?
    private var livePreviewTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    private var activeAudioURL: URL?
    private var generation = 0

    init(
        storageRoot: URL,
        settingsProvider: @escaping () -> AppSettings,
        canStart: @escaping () -> Bool,
        onBusy: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.storageRoot = storageRoot
        self.settingsProvider = settingsProvider
        self.canStart = canStart
        self.onBusy = onBusy
        self.onError = onError
        inputMonitor.triggerModeProvider = { [weak self] in
            self?.settingsProvider().dictationTriggerMode ?? .pushToTalk
        }
        inputMonitor.shortcutProvider = { .handyDefault }
        inputMonitor.onStart = { [weak self] in self?.start(source: "shortcut") }
        inputMonitor.onStop = { [weak self] in self?.finishRecordingAndTranscribe(source: "shortcut") }
        inputMonitor.onToggle = { [weak self] in self?.toggle(source: "shortcut") }
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
                stopLivePreview(reset: true)
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
        guard case .idle = state else { return }
        guard canStart() else {
            onBusy()
            return
        }
        let startedAt = Date()
        generation += 1
        let session = generation
        resetLivePreview()
        Task {
            guard await MicRecorder.requestPermission() else {
                guard self.generation == session else { return }
                self.onError("Microphone permission denied.")
                return
            }
            guard self.generation == session else { return }
            do {
                let audioURL = try self.nextAudioURL(startedAt: startedAt)
                let pausedMedia = MediaPlaybackController.pauseActiveMediaPlayers(reason: "dictation")
                if !pausedMedia.isEmpty {
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard self.generation == session else { return }
                try await self.startRecorder(writingTo: audioURL)
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
            } catch {
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
        guard case .recording(let startedAt) = state, let audioURL = activeAudioURL else { return }
        stopLivePreview(reset: false)
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
        transcribeTask?.cancel()
        transcribeTask = Task { [weak self] in
            await self?.transcribeAndDeliver(audioURL: audioURL, startedAt: startedAt,
                                             source: source, generation: session)
        }
    }

    func cancel() {
        generation += 1
        transcribeTask?.cancel()
        transcribeTask = nil
        prewarmTask?.cancel()
        prewarmTask = nil
        stopLivePreview(reset: true)
        if case .recording = state {
            recorder.stop()
        }
        if let activeAudioURL {
            try? FileManager.default.removeItem(at: activeAudioURL)
        }
        activeAudioURL = nil
        state = .idle
        stopTick()
        refreshOverlay()
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
            let delivered = deliver(text, mode: config.dictationOutputMode)
            if !delivered {
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

    private func deliver(_ text: String, mode: DictationOutputMode) -> Bool {
        switch mode {
        case .pasteIntoFocusedApp:
            return inserter.insertViaPaste(text) || inserter.insert(text)
        case .copyToClipboard:
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func complete() {
        state = .idle
        stopTick()
        resetLivePreview()
        refreshOverlay()
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
        let choice = config.transcriptionModel
        switch choice {
        case .parakeetV3: await ParakeetEngine.shared.setVariant(.v3)
        case .parakeetV2: await ParakeetEngine.shared.setVariant(.v2)
        default: break
        }
        return try await choice.engine.transcribe(
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

                let snapshot: URL
                do {
                    snapshot = try Self.copyLivePreviewSnapshot(
                        from: audioURL,
                        storageRoot: storageRoot)
                } catch {
                    try await Task.sleep(for: .milliseconds(700))
                    continue
                }
                lastPreviewedDuration = duration
                isLivePreviewWorking = true
                livePreviewStatus = liveTranscript.isEmpty ? "Listening" : "Updating"
                refreshOverlay()

                do {
                    let transcript = try await Self.transcribe(snapshot, config: config)
                    try Task.checkCancellation()
                    let text = Transcript.normalizedText(
                        transcript.segments.map(\.displayText).joined(separator: " "))
                    if generation == session, !text.isEmpty {
                        liveTranscript = DictationLiveTranscript.preview(from: text)
                        livePreviewStatus = "Live"
                        refreshOverlay()
                    }
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: snapshot)
                    throw CancellationError()
                } catch {
                    if generation == session {
                        livePreviewStatus = liveTranscript.isEmpty ? "Listening" : "Live"
                        lokalbotLog("dictation live preview skipped: \(error.localizedDescription)")
                    }
                }
                try? FileManager.default.removeItem(at: snapshot)
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

    private func stopLivePreview(reset: Bool) {
        livePreviewTask?.cancel()
        livePreviewTask = nil
        isLivePreviewWorking = false
        if reset {
            resetLivePreview()
        }
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

    private static func copyLivePreviewSnapshot(from audioURL: URL, storageRoot: URL) throws -> URL {
        let dir = storageRoot.appendingPathComponent("dictation-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = audioURL.pathExtension.isEmpty ? "caf" : audioURL.pathExtension
        let destination = dir.appendingPathComponent(
            "\(audioURL.deletingPathExtension().lastPathComponent)-live-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: audioURL, to: destination)
        return destination
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
                try await Self.prepare(choice)
                lokalbotLog("dictation prewarm ready model=\(choice.rawValue) reason=\(reason)")
            } catch {
                lokalbotLog("dictation prewarm FAILED model=\(choice.rawValue): \(error.localizedDescription)")
            }
        }
    }

    private static func prepare(_ choice: TranscriptionModelChoice) async throws {
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
        case .graniteSpeech:
            try await GraniteSpeechEngine.shared.prepare()
        case .whisperLarge:
            try await WhisperEngine.shared.prepare()
        case .cohere:
            try await CohereEngine.shared.prepare()
        case .senseVoice:
            try await OnnxTranscriptionEngine.senseVoice.prepare()
        case .gigaamRussian:
            try await OnnxTranscriptionEngine.gigaamRussian.prepare()
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
