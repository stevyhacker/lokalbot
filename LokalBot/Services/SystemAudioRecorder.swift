import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio

/// Records the audio *output* of one process (the meeting app) using
/// Core Audio process taps (macOS 14.4+) — the "Them" track.
///
/// Pipeline: PID → process AudioObject → CATapDescription → process tap
/// → private aggregate device containing the tap → IOProc → AAC `.m4a`.
/// Pattern follows Apple's "Capturing system audio with Core Audio taps"
/// and insidegui/AudioCap. Requires the "System Audio Recording" TCC
/// permission (NSAudioCaptureUsageDescription) and no App Sandbox.
final class SystemAudioRecorder {

    enum RecorderError: LocalizedError {
        case processNotFound
        case coreAudio(String, OSStatus)
        case badTapFormat

        var errorDescription: String? {
            switch self {
            case .processNotFound:
                "Could not locate the meeting app's audio process. The system audio tap requires macOS 14.4+."
            case .coreAudio(let stage, let code):
                "Core Audio \(stage) failed (\(code))."
            case .badTapFormat:
                "Core Audio tap returned an unsupported audio format."
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var previewTee: AudioPreviewTee?
    private var previewTeeURL: URL?
    private var tapFormat: AVAudioFormat?
    private var outputURL: URL?
    private var framesWritten: AVAudioFramePosition = 0
    private var audibleFramesWritten: AVAudioFramePosition = 0
    private var recordingSampleRate: Double = 0
    private var lastAudioWriteAt: Date?
    private var lastAudibleWriteAt: Date?
    private var lastRMSLevel: Float = 0
    private var peakRMSLevel: Float = 0
    private static let audibleRMSThreshold: Float = 0.0005

    /// IOProc writes hop here so the Core Audio real-time thread never
    /// blocks on AAC encoding or filesystem I/O. Serial → ordered writes.
    private let ioQueue = DispatchQueue(label: "lokalbot.systemaudio.write",
                                        qos: .userInitiated)

    /// Captured app's PID, so we can detect the process terminating and
    /// stop instead of silently recording a blank track.
    private var capturedPID: pid_t = 0
    private var terminationObserver: NSObjectProtocol?

    /// Fired on the main thread when the captured process exits before
    /// `stop()` was called (crash, user-quit, browser tab close).
    var onCapturedProcessTerminated: (() -> Void)?

    struct CaptureHealth {
        let duration: TimeInterval
        let audibleDuration: TimeInterval
        let lastAudioWriteAt: Date?
        let lastAudibleWriteAt: Date?
        let capturedPID: pid_t
        let lastRMSLevel: Float
        let peakRMSLevel: Float
    }

    /// `previewTee` mirrors the capture into a snapshot-safe PCM `.caf` for
    /// the live meeting transcript — best-effort, never fails the recording.
    func start(capturingPID pid: pid_t, writingTo url: URL, previewTee previewURL: URL? = nil) throws {
        // 1. Translate the PID to its Core Audio process object.
        guard let processObject = CoreAudioUtils.translatePIDToProcessObject(pid: pid) else {
            throw RecorderError.processNotFound
        }

        do {
            outputURL = url
            previewTeeURL = previewURL
            ioQueue.sync {
                framesWritten = 0
                audibleFramesWritten = 0
                recordingSampleRate = 0
                lastAudioWriteAt = nil
                lastAudibleWriteAt = nil
                lastRMSLevel = 0
                peakRMSLevel = 0
            }
            try attachTap(processObject: processObject, writingTo: url)
        } catch {
            cleanup(closeFile: true)
            throw error
        }

        // Latch the PID only after a successful build so cleanup() on a
        // partial start doesn't leave a stale watcher running.
        installTerminationObserver(for: pid)
    }

    /// Switches the Core Audio process tap to a new PID while keeping the
    /// existing `system.m4a` writer open. Browser meetings often move output
    /// between helper processes; closing/reopening the file would discard the
    /// audio already captured before that handoff.
    func reattach(capturingPID pid: pid_t) throws {
        guard let outputURL else { throw RecorderError.processNotFound }
        guard let processObject = CoreAudioUtils.translatePIDToProcessObject(pid: pid) else {
            throw RecorderError.processNotFound
        }
        teardownTap()
        do {
            try attachTap(processObject: processObject, writingTo: outputURL)
            installTerminationObserver(for: pid)
        } catch {
            teardownTap()
            throw error
        }
    }

    func captureHealth() -> CaptureHealth {
        ioQueue.sync {
            let duration = recordingSampleRate > 0
                ? Double(framesWritten) / recordingSampleRate
                : 0
            let audibleDuration = recordingSampleRate > 0
                ? Double(audibleFramesWritten) / recordingSampleRate
                : 0
            return CaptureHealth(duration: duration,
                                 audibleDuration: audibleDuration,
                                 lastAudioWriteAt: lastAudioWriteAt,
                                 lastAudibleWriteAt: lastAudibleWriteAt,
                                 capturedPID: capturedPID,
                                 lastRMSLevel: lastRMSLevel,
                                 peakRMSLevel: peakRMSLevel)
        }
    }

    private func attachTap(processObject: AudioObjectID, writingTo url: URL) throws {
        // 2. Create a stereo-mixdown tap on that process only.
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObject])
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted   // user still hears the meeting
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard err == noErr else { throw RecorderError.coreAudio("CreateProcessTap", err) }

        // 3. Read the tap's stream format.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError.badTapFormat
        }

        if let existingFormat = tapFormat, !Self.formatsCompatible(existingFormat, format) {
            throw RecorderError.badTapFormat
        }
        tapFormat = format

        // 4. Private aggregate device that contains (auto-starts) the tap.
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LokalBot Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        err = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggregateID)
        guard err == noErr else { throw RecorderError.coreAudio("CreateAggregateDevice", err) }

        // 5. Output file (PCM → AAC handled by AVAudioFile). Reattaches keep
        // this writer open so samples already captured remain in the same M4A.
        if file == nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 96_000,
            ]
            file = try AVAudioFile(forWriting: url,
                                   settings: settings,
                                   commonFormat: format.commonFormat,
                                   interleaved: format.isInterleaved)
            previewTee = previewTeeURL.flatMap { AudioPreviewTee(url: $0, sourceFormat: format) }
            ioQueue.sync {
                recordingSampleRate = format.sampleRate
            }
        }

        // 6. IOProc: tap buffers arrive as the aggregate device's input.
        //    The Core Audio buffer list is only valid for the duration of
        //    this callback, and the AAC encoder must not run on the real-time
        //    audio thread — copy the samples, then hop to a serial queue.
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self, let fmt = self.tapFormat,
                  let src = AVAudioPCMBuffer(pcmFormat: fmt,
                                             bufferListNoCopy: inInputData,
                                             deallocator: nil),
                  src.frameLength > 0,
                  let copy = AVAudioPCMBuffer(pcmFormat: fmt,
                                              frameCapacity: src.frameLength),
                  let srcChannels = src.floatChannelData,
                  let dstChannels = copy.floatChannelData
            else { return }
            copy.frameLength = src.frameLength
            let rmsLevel = Self.copyAndMeasureRMS(source: srcChannels,
                                                  destination: dstChannels,
                                                  channelCount: Int(fmt.channelCount),
                                                  frameLength: Int(src.frameLength))
            // Snapshot the file ref on the audio thread (atomic class read);
            // strongly retained by the dispatched block until the write returns.
            let fileRef = self.file
            let teeRef = self.previewTee
            self.ioQueue.async {
                guard let fileRef else { return }
                do {
                    try fileRef.write(from: copy)
                    teeRef?.write(copy)
                    let now = Date()
                    self.framesWritten += AVAudioFramePosition(copy.frameLength)
                    self.lastAudioWriteAt = now
                    self.lastRMSLevel = rmsLevel
                    self.peakRMSLevel = max(self.peakRMSLevel, rmsLevel)
                    if rmsLevel >= Self.audibleRMSThreshold {
                        self.audibleFramesWritten += AVAudioFramePosition(copy.frameLength)
                        self.lastAudibleWriteAt = now
                    }
                } catch {
                    NSLog("SystemAudioRecorder write failed: \(error.localizedDescription)")
                }
            }
        }
        guard err == noErr else { throw RecorderError.coreAudio("CreateIOProc", err) }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else { throw RecorderError.coreAudio("DeviceStart", err) }
    }

    func stop() {
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        cleanup(closeFile: true)
    }

    private func installTerminationObserver(for pid: pid_t) {
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        capturedPID = pid
        // Watch the captured process: if it dies mid-meeting, the tap goes
        // silent. Notify upstream so the meeting can end cleanly instead of
        // producing a `system.m4a` that's half audio, half blank.
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == self.capturedPID else { return }
            self.onCapturedProcessTerminated?()
        }
    }

    /// Stop the tap/aggregate without closing the file. Used for browser
    /// helper handoffs where the M4A should keep accumulating samples.
    private func teardownTap() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        // Drain any IOProc writes that were already dispatched before we
        // stopped, preserving sample order before a reattach or file close.
        ioQueue.sync {}

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// One canonical close path, used by both `stop()` and startup failures.
    /// Order matters: stop the IOProc (so no new buffers are dispatched), drain
    /// the write queue (so in-flight writes finish), release the file ref
    /// (flushes the AAC encoder), then dismantle Core Audio objects.
    private func cleanup(closeFile: Bool) {
        teardownTap()
        guard closeFile else { return }
        file = nil
        previewTee?.close()
        previewTee = nil
        previewTeeURL = nil
        tapFormat = nil
        outputURL = nil
        capturedPID = 0
        ioQueue.sync {
            framesWritten = 0
            audibleFramesWritten = 0
            recordingSampleRate = 0
            lastAudioWriteAt = nil
            lastAudibleWriteAt = nil
            lastRMSLevel = 0
            peakRMSLevel = 0
        }
    }

    private static func formatsCompatible(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private static func copyAndMeasureRMS(source: UnsafePointer<UnsafeMutablePointer<Float>>,
                                          destination: UnsafePointer<UnsafeMutablePointer<Float>>,
                                          channelCount: Int,
                                          frameLength: Int) -> Float {
        guard channelCount > 0, frameLength > 0 else { return 0 }
        let bytes = frameLength * MemoryLayout<Float>.size
        var sumSquares = 0.0
        for channel in 0..<channelCount {
            let sourceChannel = source[channel]
            let destinationChannel = destination[channel]
            memcpy(destinationChannel, sourceChannel, bytes)
            for frame in 0..<frameLength {
                let sample = Double(sourceChannel[frame])
                sumSquares += sample * sample
            }
        }
        let sampleCount = channelCount * frameLength
        return Float(sqrt(sumSquares / Double(sampleCount)))
    }
}
