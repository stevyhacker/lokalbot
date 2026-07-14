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
              Self.formatsCompatible(source.format, format),
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

    private static func formatsCompatible(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
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
    private var bufferPool: MicAudioBufferPool?
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
        }
        updateRecoveryState(.healthy)
        resetCaptureHealth(sampleRate: recordingFormat.sampleRate)

        do {
            try installTapAndStart(inputFormat: inputFormat, recordingFormat: recordingFormat)
        } catch {
            ioQueue.sync {
                file = nil
                self.recordingFormat = nil
                converter = nil
                converterInputFormat = nil
                previewTee?.close()
                previewTee = nil
            }
            bufferPool = nil
            resetCaptureHealth(sampleRate: 0)
            throw error
        }
        isRecording = true

        // The engine stops itself on device changes; restart it on the new
        // graph so the same `mic.m4a` continues uninterrupted across swaps.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    func stop() {
        isRecording = false
        reconfigurationTask?.cancel()
        reconfigurationTask = nil
        updateRecoveryState(.healthy)
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Draining the queue first preserves callback order. Then flush the
        // converter's tail before closing either output.
        ioQueue.sync {
            drainConverter()
            converter = nil
            converterInputFormat = nil
            recordingFormat = nil
            file = nil   // closes the file
            previewTee?.close()
            previewTee = nil
        }
        bufferPool = nil
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            drainAndResetConverter()
            try appendRecoverySilence(
                until: ContinuousClock.now,
                wallDate: Date(),
                format: recordingFormat)
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw RecorderError.inputUnavailable
            }
            try installTapAndStart(inputFormat: inputFormat,
                                   recordingFormat: recordingFormat,
                                   shouldDrainExistingConverter: false)
            reconfigurationTask?.cancel()
            reconfigurationTask = nil
            updateRecoveryState(.healthy)
        } catch {
            scheduleReconfigurationRetry(lastError: error.localizedDescription)
            throw error
        }
    }

    // MARK: - Engine setup

    /// Builds the converter (only when input ≠ recording format), installs
    /// the tap, and starts the engine. Shared by `start()` and the
    /// configuration-change reinstall.
    private func installTapAndStart(
        inputFormat: AVAudioFormat,
        recordingFormat: AVAudioFormat,
        shouldDrainExistingConverter: Bool = true
    ) throws {
        if shouldDrainExistingConverter {
            drainAndResetConverter()
        }
        let input = engine.inputNode
        guard let pool = MicAudioBufferPool(
            format: inputFormat,
            bufferCount: Self.bufferPoolSize,
            frameCapacity: Self.pooledBufferFrameCapacity
        ) else {
            throw RecorderError.unsupportedInputFormat
        }
        bufferPool = pool
        // Let AVAudioEngine choose the current hardware format. During a live
        // device switch, `outputFormat(forBus:)` can briefly report a stale
        // client format while the input unit has already moved to the new
        // hardware rate, and passing that stale format makes installTap raise.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            guard let pool = self.bufferPool,
                  let copy = pool.borrow(for: buffer) else {
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
                do {
                    try self?.write(copy)
                } catch {
                    NSLog("MicRecorder write failed: \(error.localizedDescription)")
                }
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            bufferPool = nil
            ioQueue.sync {
                converter = nil
                converterInputFormat = nil
            }
            throw error
        }
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
    private func handleConfigurationChange() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
                    self.engine.inputNode.removeTap(onBus: 0)
                    guard let recordingFormat = self.recordingFormat else {
                        return ReconfigurationAttemptResult.stopped
                    }
                    let inputFormat = self.engine.inputNode.outputFormat(forBus: 0)
                    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                        NSLog("MicRecorder reconfig retry: no usable input device")
                        return ReconfigurationAttemptResult.retry(
                            RecorderError.inputUnavailable.localizedDescription)
                    }
                    do {
                        self.drainAndResetConverter()
                        try self.appendRecoverySilence(
                            until: ContinuousClock.now,
                            wallDate: Date(),
                            format: recordingFormat)
                        try self.installTapAndStart(inputFormat: inputFormat,
                                                    recordingFormat: recordingFormat,
                                                    shouldDrainExistingConverter: false)
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

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else { return }
        guard let recordingFormat else {
            try file.write(from: buffer)
            previewTee?.write(buffer)
            noteWrittenAudio(buffer)
            return
        }
        guard buffer.format != recordingFormat else {
            converter = nil
            converterInputFormat = nil
            try file.write(from: buffer)
            previewTee?.write(buffer)
            noteWrittenAudio(buffer)
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
            try file.write(from: output)
            previewTee?.write(output)
            noteWrittenAudio(output)
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

    /// Device changes can leave the microphone graph stopped for several
    /// seconds. Preserve that monotonic elapsed interval as silence before rebuilding
    /// the tap so the mic timeline remains aligned with system audio and with
    /// transcript timestamps after recovery.
    private func appendRecoverySilence(
        until now: ContinuousClock.Instant,
        wallDate: Date,
        format: AVAudioFormat
    ) throws {
        try ioQueue.sync {
            healthLock.lock()
            let anchor = lastAudioWriteInstant ?? captureStartedInstant
            healthLock.unlock()
            guard let anchor, let file else { return }
            guard let plan = AudioRecoverySilencePlanner.plan(
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
            lastAudioWriteAt = wallDate
            lastAudioWriteInstant = now
            healthLock.unlock()
            if plan.wasCapped {
                NSLog(
                    "MicRecorder recovery gap capped at "
                        + "\(AudioRecoverySilencePlanner.maximumDuration)s")
            }
        }
    }

    private func noteDroppedBuffer() {
        dropCounter.recordDrop()
    }

    private func noteWrittenAudio(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let now = ContinuousClock.now
        healthLock.lock()
        if recordingSampleRate <= 0 {
            recordingSampleRate = buffer.format.sampleRate
        }
        framesWritten += AVAudioFramePosition(buffer.frameLength)
        lastAudioWriteAt = Date()
        lastAudioWriteInstant = now
        healthLock.unlock()
    }
}
