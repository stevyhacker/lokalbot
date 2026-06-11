import AVFoundation

/// Records the default input device (your voice) to an AAC `.m4a`.
/// This is the "Me" track — kept separate from system audio on purpose
/// so M2 gets speaker attribution for free (design doc §2.2).
final class MicRecorder {

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(writingTo url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 64_000,
        ]
        // commonFormat/interleaved must match the tap buffers we feed in,
        // so AVAudioFile transparently encodes PCM → AAC.
        file = try AVAudioFile(forWriting: url,
                               settings: settings,
                               commonFormat: format.commonFormat,
                               interleaved: format.isInterleaved)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            do {
                try self?.file?.write(from: buffer)
            } catch {
                // Don't crash the audio thread; surface once via NSLog.
                NSLog("MicRecorder write failed: \(error.localizedDescription)")
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil   // closes the file
    }
}
