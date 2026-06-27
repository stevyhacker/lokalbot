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
    private var tapFormat: AVAudioFormat?

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

    func start(capturingPID pid: pid_t, writingTo url: URL) throws {
        // 1. Translate the PID to its Core Audio process object.
        guard let processObject = CoreAudioUtils.translatePIDToProcessObject(pid: pid) else {
            throw RecorderError.processNotFound
        }

        do {
            try buildPipeline(processObject: processObject, writingTo: url)
        } catch {
            cleanup()
            throw error
        }

        // Latch the PID only after a successful build so cleanup() on a
        // partial start doesn't leave a stale watcher running.
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

    private func buildPipeline(processObject: AudioObjectID, writingTo url: URL) throws {
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

        // 5. Output file (PCM → AAC handled by AVAudioFile).
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

        // 6. IOProc: tap buffers arrive as the aggregate device's input.
        //    The Core Audio buffer list is only valid for the duration of
        //    this callback, and the AAC encoder must not run on the real-time
        //    audio thread — copy the samples, then hop to a serial queue.
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [weak self] _, inInputData, _, _, _ in
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
            let bytes = Int(src.frameLength) * MemoryLayout<Float>.size
            for ch in 0..<Int(fmt.channelCount) {
                memcpy(dstChannels[ch], srcChannels[ch], bytes)
            }
            // Snapshot the file ref on the audio thread (atomic class read);
            // strongly retained by the dispatched block until the write returns.
            let fileRef = self.file
            self.ioQueue.async {
                guard let fileRef else { return }
                do { try fileRef.write(from: copy) }
                catch { NSLog("SystemAudioRecorder write failed: \(error.localizedDescription)") }
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
        cleanup()
    }

    /// One canonical teardown path, used by both `stop()` and any error path
    /// inside `start()`. Order matters: stop the IOProc (so no new buffers
    /// are dispatched), drain the write queue (so in-flight writes finish),
    /// release the file ref (flushes the AAC encoder), then dismantle the
    /// Core Audio objects.
    private func cleanup() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        // Drain any IOProc writes that were already dispatched before we
        // stopped, then release the file so the AAC encoder flushes.
        ioQueue.sync {}
        file = nil
        tapFormat = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        capturedPID = 0
    }
}
