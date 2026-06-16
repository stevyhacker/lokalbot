import AVFoundation
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
            case .processNotFound: "Meeting app's audio process not found."
            case .coreAudio(let op, let status): "\(op) failed (OSStatus \(status))."
            case .badTapFormat: "Could not read tap stream format."
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var tapFormat: AVAudioFormat?

    func start(capturingPID pid: pid_t, writingTo url: URL) throws {
        // 1. Translate the PID to its Core Audio process object.
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var pidCopy = pid
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var err = withUnsafeMutablePointer(to: &pidCopy) { pidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<pid_t>.size), pidPtr,
                                       &size, &processObject)
        }
        guard err == noErr, processObject != kAudioObjectUnknown else {
            throw RecorderError.processNotFound
        }

        // 2. Create a stereo-mixdown tap on that process only.
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObject])
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted   // user still hears the meeting
        err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard err == noErr else { throw RecorderError.coreAudio("CreateProcessTap", err) }

        // 3. Read the tap's stream format.
        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        addr.mSelector = kAudioTapPropertyFormat
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            cleanup(); throw RecorderError.badTapFormat
        }
        tapFormat = format

        // 4. Private aggregate device that contains (auto-starts) the tap.
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BotinaV2 Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        err = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggregateID)
        guard err == noErr else { cleanup(); throw RecorderError.coreAudio("CreateAggregateDevice", err) }

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
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let fmt = self.tapFormat,
                  let buffer = AVAudioPCMBuffer(pcmFormat: fmt,
                                                bufferListNoCopy: inInputData,
                                                deallocator: nil) else { return }
            do { try self.file?.write(from: buffer) }
            catch { NSLog("SystemAudioRecorder write failed: \(error.localizedDescription)") }
        }
        guard err == noErr else { cleanup(); throw RecorderError.coreAudio("CreateIOProc", err) }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else { cleanup(); throw RecorderError.coreAudio("DeviceStart", err) }
    }

    func stop() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        cleanup()
        file = nil   // closes the file
    }

    private func cleanup() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
