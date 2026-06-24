import AVFoundation
import Foundation

enum AudioFileInspector {
    static let minimumTranscribableDuration: TimeInterval = 0.3

    static func duration(at url: URL) -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url) else {
            return nil
        }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        let duration = Double(file.length) / sampleRate
        return duration.isFinite ? duration : nil
    }

    static func isTranscribableAudio(at url: URL,
                                     minimumDuration: TimeInterval = minimumTranscribableDuration) -> Bool {
        guard let duration = duration(at: url) else { return false }
        return duration >= minimumDuration
    }
}
