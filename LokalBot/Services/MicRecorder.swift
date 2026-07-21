import AVFoundation

struct AudioRecoverySilencePlan: Equatable {
    let duration: TimeInterval
    let wasCapped: Bool
}

enum AudioRecoverySilencePlanner {
    static let minimumDuration: TimeInterval = 0.2
    static let maximumDuration: TimeInterval = 30

    static func plan(forElapsed elapsed: TimeInterval) -> AudioRecoverySilencePlan? {
        guard elapsed.isFinite, elapsed >= minimumDuration else { return nil }
        let duration = min(elapsed, maximumDuration)
        return AudioRecoverySilencePlan(duration: duration, wasCapped: duration < elapsed)
    }

    static func plan(forElapsed elapsed: Duration) -> AudioRecoverySilencePlan? {
        let components = elapsed.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return plan(forElapsed: seconds)
    }
}

/// Gates recovery-gap silence until a rebuilt capture graph delivers audio.
/// Starting an engine is not enough evidence: a graph can report success and
/// still never produce a buffer. Keeping this state separate also makes failed
/// retry behavior testable without requiring microphone hardware.
struct AudioRecoverySilenceCommitGate: Equatable {
    private(set) var isPending = false

    mutating func stage() {
        isPending = true
    }

    mutating func cancel() {
        isPending = false
    }

    mutating func consumeAfterCapturedBuffer(
        forElapsed elapsed: TimeInterval
    ) -> AudioRecoverySilencePlan? {
        guard isPending else { return nil }
        isPending = false
        return AudioRecoverySilencePlanner.plan(forElapsed: elapsed)
    }

    mutating func consumeAfterCapturedBuffer(
        forElapsed elapsed: Duration
    ) -> AudioRecoverySilencePlan? {
        guard isPending else { return nil }
        isPending = false
        return AudioRecoverySilencePlanner.plan(forElapsed: elapsed)
    }
}

final class MicAudioBufferPool: @unchecked Sendable {
    private let lock = NSLock()
    private let format: AVAudioFormat
    private let frameCapacity: AVAudioFrameCount
    private var buffers: [AVAudioPCMBuffer]

    init?(
        format: AVAudioFormat,
        bufferCount: Int,
        frameCapacity: AVAudioFrameCount
    ) {
        guard bufferCount > 0, frameCapacity > 0 else { return nil }
        var prepared: [AVAudioPCMBuffer] = []
        prepared.reserveCapacity(bufferCount)
        for _ in 0..<bufferCount {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCapacity
            ) else { return nil }
            prepared.append(buffer)
        }
        self.format = format
        self.frameCapacity = frameCapacity
        buffers = prepared
    }

    func borrow(for source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard source.frameLength <= frameCapacity,
              isCompatible(with: source.format),
              lock.try() else { return nil }
        defer { lock.unlock() }
        guard let buffer = buffers.popLast() else { return nil }
        buffer.frameLength = source.frameLength
        return buffer
    }

    func returnBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        buffers.append(buffer)
        lock.unlock()
    }

    var availableBufferCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffers.count
    }

    func isCompatible(with candidate: AVAudioFormat) -> Bool {
        Self.formatsCompatible(candidate, format)
    }

    private static func formatsCompatible(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }
}

/// Atomically routes real-time tap buffers to a pool matching the format Core
/// Audio actually negotiated. A `format: nil` tap is required during device
/// changes because `outputFormat(forBus:)` can be stale; this broker lets the
/// first mismatched callback request an off-thread pool rebuild instead of
/// silently dropping every subsequent buffer.
final class MicAudioBufferPoolBroker: @unchecked Sendable {
    enum BorrowResult {
        case borrowed(buffer: AVAudioPCMBuffer, pool: MicAudioBufferPool)
        case refreshNeeded(AVAudioFormat)
        case unavailable
    }

    private let lock = NSLock()
    private let bufferCount: Int
    private let frameCapacity: AVAudioFrameCount
    private var pool: MicAudioBufferPool?
    private var refreshPending = false

    init(bufferCount: Int, frameCapacity: AVAudioFrameCount) {
        self.bufferCount = bufferCount
        self.frameCapacity = frameCapacity
    }

    @discardableResult
    func install(format: AVAudioFormat) -> Bool {
        guard let replacement = MicAudioBufferPool(
            format: format,
            bufferCount: bufferCount,
            frameCapacity: frameCapacity
        ) else { return false }
        lock.lock()
        pool = replacement
        refreshPending = false
        lock.unlock()
        return true
    }

    func borrow(for source: AVAudioPCMBuffer) -> BorrowResult {
        guard lock.try() else { return .unavailable }
        guard let pool else {
            let shouldRefresh = !refreshPending
            refreshPending = true
            lock.unlock()
            return shouldRefresh ? .refreshNeeded(source.format) : .unavailable
        }
        guard pool.isCompatible(with: source.format) else {
            let shouldRefresh = !refreshPending
            refreshPending = true
            lock.unlock()
            return shouldRefresh ? .refreshNeeded(source.format) : .unavailable
        }
        lock.unlock()
        guard let buffer = pool.borrow(for: source) else { return .unavailable }
        return .borrowed(buffer: buffer, pool: pool)
    }

    func clear() {
        lock.lock()
        pool = nil
        refreshPending = false
        lock.unlock()
    }
}

final class MicRealtimeDropCounter: @unchecked Sendable {
    private let lock: NSLock
    private var count = 0

    init(lock: NSLock = NSLock()) {
        self.lock = lock
    }

    @discardableResult
    func recordDrop() -> Bool {
        guard lock.try() else { return false }
        count += 1
        lock.unlock()
        return true
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }
}

/// Records the default input device (your voice). Meeting recordings use AAC
/// `.m4a`; short-lived dictation scratch files can use PCM `.caf` to avoid
/// AAC container startup failures on some devices.
/// This is the "Me" track — kept separate from system audio on purpose
/// so M2 gets speaker attribution for free (design doc §2.2).
final class MicRecorder {

    // Recreated per session — a reused engine can hold a stale graph after
    // device changes and then fails with kAudioDeviceUnsupportedFormat ('!dev').
    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var previewTee: AudioPreviewTee?
    private var recordingFormat: AVAudioFormat?
    /// Accessed only on `ioQueue`.
    private var recoverySilenceCommitGate = AudioRecoverySilenceCommitGate()
    private var isRecording = false
    private var reconfigurationTask: Task<Void, Never>?
    private let healthLock = NSLock()
    private var framesWritten: AVAudioFramePosition = 0
    private var recordingSampleRate: Double = 0
    private var lastAudioWriteAt: Date?
    private var lastAudioWriteInstant: ContinuousClock.Instant?
    private var captureStartedInstant: ContinuousClock.Instant?
    private var recoveryState: RecoveryState = .healthy
    /// Observes `AVAudioEngineConfigurationChange` so we can rebuild the
    /// tap graph in place when the audio device changes mid-recording
    /// (AirPods plug/unplug, default-input switch, sample-rate renegotiation).
    /// Without this, the engine silently stops itself and `mic.m4a` truncates.
    private var configChangeObserver: NSObjectProtocol?

    /// Audio taps run on a real-time Core Audio thread. Keep that callback to
    /// one bounded PCM copy, then serialize conversion, AAC encoding, preview
    /// resampling, and filesystem writes here.
    private let ioQueue = DispatchQueue(label: "lokalbot.microphone.write",
                                        qos: .userInitiated)
    private static let bufferPoolSize = 16
    private static let pooledBufferFrameCapacity: AVAudioFrameCount = 32_768
    private var bufferPoolBroker: MicAudioBufferPoolBroker?
    /// Accessed only on `ioQueue`. A per-install token prevents a late callback
    /// from an old input graph from mutating or writing into its replacement.
    private var activeCaptureGraphID: UUID?
    private let dropCounter = MicRealtimeDropCounter()

    enum RecorderError: LocalizedError {
        case inputUnavailable
        case unsupportedInputFormat
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .inputUnavailable:
                "Microphone is not available right now (no usable input device). Check the input selected in System Settings → Sound."
            case .unsupportedInputFormat:
                "Microphone input format is not supported by the recorder."
            case .conversionFailed(let message):
                "Microphone audio conversion failed: \(message)"
            }
        }
    }

    enum RecoveryState: Equatable {
        case healthy
        case recovering(attempt: Int)
        case degraded(errorDescription: String)
    }

    static let maximumReconfigurationAttempts = 4

    static func reconfigurationRetryDelay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt > 0, attempt <= maximumReconfigurationAttempts else { return nil }
        return min(Double(attempt), 5)
    }

    struct CaptureHealth {
        let duration: TimeInterval
        let lastAudioWriteAt: Date?
        let isEngineRunning: Bool
        let droppedBufferCount: Int
        let recoveryState: RecoveryState
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// `previewTee` mirrors the capture into a snapshot-safe PCM `.caf` for
    /// the live meeting transcript — best-effort, never fails the recording.
    func start(writingTo url: URL, previewTee previewURL: URL? = nil) throws {
        reconfigurationTask?.cancel()
        reconfigurationTask = nil
        isRecording = false
        removeConfigurationChangeObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        ioQueue.sync { activeCaptureGraphID = nil }
        bufferPoolBroker?.clear()
        bufferPoolBroker = nil
        engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.inputUnavailable
        }
        let channelCount = min(inputFormat.channelCount, 2)
        let sampleRate = min(max(inputFormat.sampleRate, 8_000), 48_000)
        guard let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                  sampleRate: sampleRate,
                                                  channels: channelCount,
                                                  interleaved: false) else {
            throw RecorderError.unsupportedInputFormat
        }

        let settings = Self.fileSettings(for: url, recordingFormat: recordingFormat)
        let newFile = try AVAudioFile(forWriting: url,
                                      settings: settings,
                                      commonFormat: recordingFormat.commonFormat,
                                      interleaved: recordingFormat.isInterleaved)
        let newPreviewTee = previewURL.flatMap {
            AudioPreviewTee(url: $0, sourceFormat: recordingFormat)
        }
        ioQueue.sync {
            file = newFile
            self.recordingFormat = recordingFormat
            previewTee = newPreviewTee
            converter = nil
            converterInputFormat = nil
            recoverySilenceCommitGate.cancel()
        }
        updateRecoveryState(.healthy)
        resetCaptureHealth(sampleRate: recordingFormat.sampleRate)

        isRecording = true
        observeConfigurationChanges(for: engine)
        do {
            try installTapAndStart(inputFormat: inputFormat, recordingFormat: recordingFormat)
        } catch {
            isRecording = false
            reconfigurationTask?.cancel()
            reconfigurationTask = nil
            removeConfigurationChangeObserver()
            ioQueue.sync {
                file = nil
                self.recordingFormat = nil
                converter = nil
                converterInputFormat = nil
                previewTee?.close()
                previewTee = nil
                recoverySilenceCommitGate.cancel()
            }
            bufferPoolBroker?.clear()
            bufferPoolBroker = nil
            resetCaptureHealth(sampleRate: 0)
            throw error
        }
    }

    func stop() {
        isRecording = false
        reconfigurationTask?.cancel()
        reconfigurationTask = nil
        updateRecoveryState(.healthy)
        removeConfigurationChangeObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Draining the queue first preserves callback order. Then flush the
        // converter's tail before closing either output.
        ioQueue.sync {
            activeCaptureGraphID = nil
            drainConverter()
            converter = nil
            converterInputFormat = nil
            recoverySilenceCommitGate.cancel()
            recordingFormat = nil
            file = nil   // closes the file
            previewTee?.close()
            previewTee = nil
        }
        bufferPoolBroker?.clear()
        bufferPoolBroker = nil
    }

    func captureHealth() -> CaptureHealth {
        healthLock.lock()
        let duration = recordingSampleRate > 0
            ? Double(framesWritten) / recordingSampleRate
            : 0
        let lastAudioWriteAt = self.lastAudioWriteAt
        let recoveryState = self.recoveryState
        healthLock.unlock()
        let droppedBufferCount = dropCounter.snapshot()
        return CaptureHealth(duration: duration,
                             lastAudioWriteAt: lastAudioWriteAt,
                             isEngineRunning: engine.isRunning,
                             droppedBufferCount: droppedBufferCount,
                             recoveryState: recoveryState)
    }

    func restartCapture() throws {
        guard isRecording, let recordingFormat else { return }
        do {
            try rebuildCaptureGraph(recordingFormat: recordingFormat)
            reconfigurationTask?.cancel()
            reconfigurationTask = nil
            updateRecoveryState(.healthy)
        } catch {
            scheduleReconfigurationRetry(lastError: error.localizedDescription)
            throw error
        }
    }

    // MARK: - Engine setup

    /// Reconfiguration can leave `AVAudioEngine`'s input node pinned to the
    /// previous hardware rate. Reusing that graph makes every retry request the
    /// stale tap format. Build a completely new graph, while retaining the
    /// session's output file and recording format so capture can continue in
    /// the same artifact.
    private func rebuildCaptureGraph(recordingFormat: AVAudioFormat) throws {
        removeConfigurationChangeObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        ioQueue.sync { activeCaptureGraphID = nil }
        bufferPoolBroker?.clear()
        bufferPoolBroker = nil
        drainAndResetConverter()
        ioQueue.sync {
            recoverySilenceCommitGate.cancel()
        }

        let replacementEngine = AVAudioEngine()
        engine = replacementEngine
        let inputFormat = replacementEngine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.inputUnavailable
        }

        observeConfigurationChanges(for: replacementEngine)
        do {
            try installTapAndStart(inputFormat: inputFormat,
                                   recordingFormat: recordingFormat,
                                   shouldDrainExistingConverter: false,
                                   stageRecoverySilence: true)
        } catch {
            removeConfigurationChangeObserver()
            replacementEngine.inputNode.removeTap(onBus: 0)
            replacementEngine.stop()
            bufferPoolBroker?.clear()
            bufferPoolBroker = nil
            throw error
        }
    }

    /// Builds the converter (only when input ≠ recording format), installs
    /// the tap, and starts the engine. Shared by `start()` and the
    /// configuration-change reinstall.
    private func installTapAndStart(
        inputFormat: AVAudioFormat,
        recordingFormat: AVAudioFormat,
        shouldDrainExistingConverter: Bool = true,
        stageRecoverySilence: Bool = false
    ) throws {
        if shouldDrainExistingConverter {
            drainAndResetConverter()
        }
        let input = engine.inputNode
        let broker = MicAudioBufferPoolBroker(
            bufferCount: Self.bufferPoolSize,
            frameCapacity: Self.pooledBufferFrameCapacity)
        guard broker.install(format: inputFormat) else {
            throw RecorderError.unsupportedInputFormat
        }
        bufferPoolBroker?.clear()
        bufferPoolBroker = broker
        let captureGraphID = UUID()
        ioQueue.sync { activeCaptureGraphID = captureGraphID }
        // Let AVAudioEngine choose the current hardware format. During a live
        // device switch, `outputFormat(forBus:)` can briefly report a stale
        // client format while the input unit has already moved to the new
        // hardware rate, and passing that stale format makes installTap raise.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self, broker] buffer, _ in
            guard let self else { return }
            let capturedAt = ContinuousClock.now
            let copy: AVAudioPCMBuffer
            let pool: MicAudioBufferPool
            switch broker.borrow(for: buffer) {
            case .borrowed(let borrowedBuffer, let borrowedPool):
                copy = borrowedBuffer
                pool = borrowedPool
            case .refreshNeeded(let negotiatedFormat):
                self.ioQueue.async { [weak self] in
                    guard let self, self.activeCaptureGraphID == captureGraphID else { return }
                    if !broker.install(format: negotiatedFormat) {
                        broker.clear()
                        NSLog("MicRecorder could not allocate a pool for the negotiated input format")
                    }
                }
                self.noteDroppedBuffer()
                return
            case .unavailable:
                self.noteDroppedBuffer()
                return
            }
            guard Self.copyBuffer(buffer, into: copy) else {
                self.ioQueue.async { [pool] in pool.returnBuffer(copy) }
                self.noteDroppedBuffer()
                return
            }
            self.ioQueue.async { [weak self, pool] in
                defer { pool.returnBuffer(copy) }
                guard let self, self.activeCaptureGraphID == captureGraphID else { return }
                do {
                    try self.write(copy, capturedAt: capturedAt)
                } catch {
                    NSLog("MicRecorder write failed: \(error.localizedDescription)")
                }
            }
        }
        if stageRecoverySilence {
            ioQueue.sync {
                recoverySilenceCommitGate.stage()
            }
        }
        do {
            engine.prepare()
            try engine.start()
            guard engine.isRunning else { throw RecorderError.inputUnavailable }
        } catch {
            input.removeTap(onBus: 0)
            bufferPoolBroker?.clear()
            bufferPoolBroker = nil
            ioQueue.sync {
                if activeCaptureGraphID == captureGraphID {
                    activeCaptureGraphID = nil
                }
                converter = nil
                converterInputFormat = nil
                if stageRecoverySilence {
                    recoverySilenceCommitGate.cancel()
                }
            }
            throw error
        }
    }

    private func observeConfigurationChanges(for observedEngine: AVAudioEngine) {
        removeConfigurationChangeObserver()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: observedEngine,
            queue: .main
        ) { [weak self] notification in
            guard let changedEngine = notification.object as? AVAudioEngine else { return }
            self?.handleConfigurationChange(for: changedEngine)
        }
    }

    private func removeConfigurationChangeObserver() {
        guard let configChangeObserver else { return }
        NotificationCenter.default.removeObserver(configChangeObserver)
        self.configChangeObserver = nil
    }

    private static func fileSettings(for url: URL, recordingFormat: AVAudioFormat) -> [String: Any] {
        if url.pathExtension.lowercased() == "caf" {
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: recordingFormat.sampleRate,
                AVNumberOfChannelsKey: Int(recordingFormat.channelCount),
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: !recordingFormat.isInterleaved,
            ]
        }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: recordingFormat.sampleRate,
            AVNumberOfChannelsKey: Int(recordingFormat.channelCount),
            AVEncoderBitRateKey: 64_000,
        ]
    }

    /// Posted asynchronously when the audio device changes. The engine has
    /// already stopped itself; remove the old tap and let the retry loop rebuild
    /// the graph after Core Audio has settled. Reinstalling immediately can hit
    /// AVAudioEngine's transient "config change pending" state.
    private func handleConfigurationChange(for changedEngine: AVAudioEngine) {
        guard isRecording, engine === changedEngine else { return }
        removeConfigurationChangeObserver()
        changedEngine.inputNode.removeTap(onBus: 0)
        changedEngine.stop()
        bufferPoolBroker?.clear()
        bufferPoolBroker = nil
        scheduleReconfigurationRetry(lastError: "The audio input configuration changed.")
    }

    private enum ReconfigurationAttemptResult: Sendable {
        case recovered
        case retry(String)
        case stopped
    }

    private func scheduleReconfigurationRetry(lastError initialError: String) {
        guard isRecording else { return }
        guard reconfigurationTask == nil else { return }
        updateRecoveryState(.recovering(attempt: 0))
        reconfigurationTask = Task { [weak self] in
            var lastError = initialError
            for attempt in 1...Self.maximumReconfigurationAttempts {
                guard let delay = Self.reconfigurationRetryDelay(forAttempt: attempt) else { break }
                self?.updateRecoveryState(.recovering(attempt: attempt))
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let result = await MainActor.run { [weak self] in
                    guard let self, self.isRecording else {
                        return ReconfigurationAttemptResult.stopped
                    }
                    guard let recordingFormat = self.recordingFormat else {
                        return ReconfigurationAttemptResult.stopped
                    }
                    do {
                        try self.rebuildCaptureGraph(recordingFormat: recordingFormat)
                        NSLog("MicRecorder reconfig retry succeeded")
                        self.reconfigurationTask = nil
                        self.updateRecoveryState(.healthy)
                        return ReconfigurationAttemptResult.recovered
                    } catch {
                        NSLog("MicRecorder reconfig retry failed: \(error.localizedDescription)")
                        return ReconfigurationAttemptResult.retry(error.localizedDescription)
                    }
                }
                switch result {
                case .recovered, .stopped:
                    return
                case .retry(let errorDescription):
                    lastError = errorDescription
                }
            }
            guard !Task.isCancelled else { return }
            let terminalError = lastError
            await MainActor.run { [weak self] in
                guard let self, self.isRecording else { return }
                self.reconfigurationTask = nil
                self.updateRecoveryState(.degraded(errorDescription: terminalError))
                NSLog(
                    "MicRecorder recovery exhausted after \(Self.maximumReconfigurationAttempts) attempts: \(terminalError)")
            }
        }
    }

    /// Flush the converter's internal buffer on stop. Without this, the tail
    /// (the last few hundred ms — more with resampling) is dropped because
    /// the streaming write loop only ever signals `.noDataNow`, never EOS.
    private func drainAndResetConverter() {
        ioQueue.sync {
            drainConverter()
            converter = nil
            converterInputFormat = nil
        }
    }

    private func drainConverter() {
        guard let converter, let recordingFormat, let file else { return }
        // Loop because the converter may need multiple output buffers to
        // emit everything it has buffered (especially with resampling).
        for _ in 0..<8 {
            guard let tail = AVAudioPCMBuffer(pcmFormat: recordingFormat,
                                              frameCapacity: 4096) else { return }
            var err: NSError?
            let status = converter.convert(to: tail, error: &err) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if tail.frameLength > 0 {
                do { try file.write(from: tail) } catch {
                    NSLog("MicRecorder drain write failed: \(error.localizedDescription)")
                    return
                }
            }
            if status == .endOfStream || status == .error || tail.frameLength == 0 {
                return
            }
        }
    }

    private func write(
        _ buffer: AVAudioPCMBuffer,
        capturedAt: ContinuousClock.Instant
    ) throws {
        guard let file else { return }
        let bufferDuration = buffer.format.sampleRate > 0
            ? Double(buffer.frameLength) / buffer.format.sampleRate
            : 0
        let bufferStartedAt = capturedAt.advanced(by: .seconds(-bufferDuration))
        guard let recordingFormat else {
            try file.write(from: buffer)
            previewTee?.write(buffer)
            noteWrittenAudio(buffer, endedAt: capturedAt)
            return
        }
        guard buffer.format != recordingFormat else {
            converter = nil
            converterInputFormat = nil
            try appendPendingRecoverySilence(
                until: bufferStartedAt,
                format: recordingFormat,
                file: file)
            try file.write(from: buffer)
            previewTee?.write(buffer)
            noteWrittenAudio(buffer, endedAt: capturedAt)
            return
        }
        if converter == nil || converterInputFormat != buffer.format {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: recordingFormat) else {
                throw RecorderError.unsupportedInputFormat
            }
            converter = newConverter
            converterInputFormat = buffer.format
        }
        guard let converter else { return }
        let sampleRateRatio = recordingFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRateRatio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: recordingFormat,
                                            frameCapacity: max(frameCapacity, 1)) else {
            throw RecorderError.unsupportedInputFormat
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            throw RecorderError.conversionFailed(conversionError?.localizedDescription ?? "unknown error")
        }
        if output.frameLength > 0 {
            try appendPendingRecoverySilence(
                until: bufferStartedAt,
                format: recordingFormat,
                file: file)
            try file.write(from: output)
            previewTee?.write(output)
            noteWrittenAudio(output, endedAt: capturedAt)
        }
    }

    /// Makes the tap buffer safe to retain after the callback returns. Copying
    /// through `AudioBufferList` handles both interleaved and planar layouts.
    static func copyBuffer(
        _ source: AVAudioPCMBuffer,
        into destination: AVAudioPCMBuffer
    ) -> Bool {
        guard source.frameLength > 0,
              source.frameLength <= destination.frameCapacity else { return false }
        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return false }
        for (src, dst) in zip(sourceBuffers, destinationBuffers) {
            guard src.mDataByteSize <= dst.mDataByteSize,
                  let srcData = src.mData,
                  let dstData = dst.mData
            else { return false }
            memcpy(dstData, srcData, Int(src.mDataByteSize))
        }
        return true
    }

    private func resetCaptureHealth(sampleRate: Double) {
        let now = ContinuousClock.now
        healthLock.lock()
        framesWritten = 0
        recordingSampleRate = sampleRate
        lastAudioWriteAt = nil
        lastAudioWriteInstant = nil
        captureStartedInstant = sampleRate > 0 ? now : nil
        recoveryState = .healthy
        healthLock.unlock()
        dropCounter.reset()
    }

    private func updateRecoveryState(_ state: RecoveryState) {
        healthLock.lock()
        recoveryState = state
        healthLock.unlock()
    }

    /// Preserve a recovery gap only after the rebuilt graph delivers a real
    /// buffer. Failed starts and nominally-running graphs that never capture
    /// audio therefore cannot inflate the file or its reported duration.
    /// Called only on `ioQueue` immediately before the recovered buffer write.
    private func appendPendingRecoverySilence(
        until now: ContinuousClock.Instant,
        format: AVAudioFormat,
        file: AVAudioFile
    ) throws {
        healthLock.lock()
        let anchor = lastAudioWriteInstant ?? captureStartedInstant
        healthLock.unlock()
        guard let anchor else {
            recoverySilenceCommitGate.cancel()
            return
        }
        guard let plan = recoverySilenceCommitGate.consumeAfterCapturedBuffer(
            forElapsed: anchor.duration(to: now)),
              format.sampleRate > 0 else { return }

        var remaining = AVAudioFramePosition(plan.duration * format.sampleRate)
        var appended: AVAudioFramePosition = 0
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, 4_096))
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                throw RecorderError.unsupportedInputFormat
            }
            silence.frameLength = count
            let buffers = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
            for buffer in buffers where buffer.mData != nil {
                memset(buffer.mData!, 0, Int(buffer.mDataByteSize))
            }
            try file.write(from: silence)
            previewTee?.write(silence)
            appended += AVAudioFramePosition(count)
            remaining -= AVAudioFramePosition(count)
        }
        healthLock.lock()
        framesWritten += appended
        healthLock.unlock()
        if plan.wasCapped {
            NSLog(
                "MicRecorder recovery gap capped at "
                    + "\(AudioRecoverySilencePlanner.maximumDuration)s")
        }
    }

    private func noteDroppedBuffer() {
        dropCounter.recordDrop()
    }

    private func noteWrittenAudio(
        _ buffer: AVAudioPCMBuffer,
        endedAt: ContinuousClock.Instant
    ) {
        guard buffer.frameLength > 0 else { return }
        healthLock.lock()
        if recordingSampleRate <= 0 {
            recordingSampleRate = buffer.format.sampleRate
        }
        framesWritten += AVAudioFramePosition(buffer.frameLength)
        lastAudioWriteAt = Date()
        lastAudioWriteInstant = endedAt
        healthLock.unlock()
    }
}
