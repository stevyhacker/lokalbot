import AVFoundation

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
    private var recordingFormat: AVAudioFormat?
    private var isRecording = false
    private var reconfigurationTask: Task<Void, Never>?
    private let healthLock = NSLock()
    private var framesWritten: AVAudioFramePosition = 0
    private var recordingSampleRate: Double = 0
    private var lastAudioWriteAt: Date?
    /// Observes `AVAudioEngineConfigurationChange` so we can rebuild the
    /// tap graph in place when the audio device changes mid-recording
    /// (AirPods plug/unplug, default-input switch, sample-rate renegotiation).
    /// Without this, the engine silently stops itself and `mic.m4a` truncates.
    private var configChangeObserver: NSObjectProtocol?

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

    struct CaptureHealth {
        let duration: TimeInterval
        let lastAudioWriteAt: Date?
        let isEngineRunning: Bool
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(writingTo url: URL) throws {
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
        file = try AVAudioFile(forWriting: url,
                               settings: settings,
                               commonFormat: recordingFormat.commonFormat,
                               interleaved: recordingFormat.isInterleaved)
        self.recordingFormat = recordingFormat
        resetCaptureHealth(sampleRate: recordingFormat.sampleRate)

        do {
            try installTapAndStart(inputFormat: inputFormat, recordingFormat: recordingFormat)
        } catch {
            file = nil
            self.recordingFormat = nil
            converter = nil
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
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Drain the converter's internal buffer so the last fraction of a
        // second isn't lost; without this, every recording is truncated.
        drainConverter()
        converter = nil
        recordingFormat = nil
        file = nil   // closes the file
    }

    func captureHealth() -> CaptureHealth {
        healthLock.lock()
        let duration = recordingSampleRate > 0
            ? Double(framesWritten) / recordingSampleRate
            : 0
        let lastAudioWriteAt = self.lastAudioWriteAt
        healthLock.unlock()
        return CaptureHealth(duration: duration,
                             lastAudioWriteAt: lastAudioWriteAt,
                             isEngineRunning: engine.isRunning)
    }

    func restartCapture() throws {
        guard isRecording, let recordingFormat else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            scheduleReconfigurationRetry()
            throw RecorderError.inputUnavailable
        }
        do {
            try installTapAndStart(inputFormat: inputFormat,
                                   recordingFormat: recordingFormat)
            reconfigurationTask?.cancel()
            reconfigurationTask = nil
        } catch {
            scheduleReconfigurationRetry()
            throw error
        }
    }

    // MARK: - Engine setup

    /// Builds the converter (only when input ≠ recording format), installs
    /// the tap, and starts the engine. Shared by `start()` and the
    /// configuration-change reinstall.
    private func installTapAndStart(inputFormat: AVAudioFormat,
                                    recordingFormat: AVAudioFormat) throws {
        if inputFormat == recordingFormat {
            converter = nil
        } else if let conv = AVAudioConverter(from: inputFormat, to: recordingFormat) {
            converter = conv
        } else {
            throw RecorderError.unsupportedInputFormat
        }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            do {
                try self?.write(buffer)
            } catch {
                // Don't crash the audio thread; surface once via NSLog.
                NSLog("MicRecorder write failed: \(error.localizedDescription)")
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            converter = nil
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
    /// already stopped itself; rebuild the tap + converter for the new input
    /// format (keeping the original on-disk format) and restart, so the same
    /// `mic.m4a` continues across the swap instead of truncating.
    private func handleConfigurationChange() {
        guard isRecording else { return }
        guard let recordingFormat else { return }
        engine.inputNode.removeTap(onBus: 0)
        let newInputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard newInputFormat.sampleRate > 0, newInputFormat.channelCount > 0 else {
            NSLog("MicRecorder reconfig: no usable input device after change")
            scheduleReconfigurationRetry()
            return
        }
        do {
            try installTapAndStart(inputFormat: newInputFormat,
                                   recordingFormat: recordingFormat)
            reconfigurationTask?.cancel()
            reconfigurationTask = nil
        } catch {
            NSLog("MicRecorder reconfig failed: \(error.localizedDescription)")
            scheduleReconfigurationRetry()
        }
    }

    private func scheduleReconfigurationRetry() {
        guard isRecording else { return }
        guard reconfigurationTask == nil else { return }
        reconfigurationTask = Task { [weak self] in
            var attempt = 1
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(Double(attempt), 5.0)))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.isRecording else { return }
                    self.engine.inputNode.removeTap(onBus: 0)
                    guard let recordingFormat = self.recordingFormat else { return }
                    let inputFormat = self.engine.inputNode.outputFormat(forBus: 0)
                    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                        NSLog("MicRecorder reconfig retry: no usable input device")
                        return
                    }
                    do {
                        try self.installTapAndStart(inputFormat: inputFormat,
                                                    recordingFormat: recordingFormat)
                        NSLog("MicRecorder reconfig retry succeeded")
                        self.reconfigurationTask?.cancel()
                        self.reconfigurationTask = nil
                    } catch {
                        NSLog("MicRecorder reconfig retry failed: \(error.localizedDescription)")
                    }
                }
                attempt += 1
            }
        }
    }

    /// Flush the converter's internal buffer on stop. Without this, the tail
    /// (the last few hundred ms — more with resampling) is dropped because
    /// the streaming write loop only ever signals `.noDataNow`, never EOS.
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
                do { try file.write(from: tail) }
                catch {
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
        guard let converter, let recordingFormat else {
            try file.write(from: buffer)
            noteWrittenAudio(buffer)
            return
        }
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
            noteWrittenAudio(output)
        }
    }

    private func resetCaptureHealth(sampleRate: Double) {
        healthLock.lock()
        framesWritten = 0
        recordingSampleRate = sampleRate
        lastAudioWriteAt = nil
        healthLock.unlock()
    }

    private func noteWrittenAudio(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        healthLock.lock()
        if recordingSampleRate <= 0 {
            recordingSampleRate = buffer.format.sampleRate
        }
        framesWritten += AVAudioFramePosition(buffer.frameLength)
        lastAudioWriteAt = Date()
        healthLock.unlock()
    }
}
