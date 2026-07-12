import Foundation

/// Resolves the durable AAC tracks and the crash-safe PCM preview tees for one
/// meeting. A process crash can leave `mic.m4a` / `system.m4a` unreadable
/// because their MP4 containers were never finalized; the append-only CAF tees
/// remain readable and must stay available for transcription and playback.
enum MeetingAudioFiles {

    /// Container finalization and the PCM tee can differ by a small encoder
    /// tail. A larger gap means the primary track was truncated and the CAF is
    /// the more complete recording.
    private static let completenessTolerance: TimeInterval = 2

    enum Track: String, CaseIterable {
        case mic
        case system

        var primaryFileName: String { "\(rawValue).m4a" }

        var recoveryFileName: String {
            switch self {
            case .mic: AudioPreviewTee.micFileName
            case .system: AudioPreviewTee.systemFileName
            }
        }
    }

    static func primaryURL(for track: Track, in folder: URL) -> URL {
        folder.appendingPathComponent(track.primaryFileName)
    }

    static func recoveryURL(for track: Track, in folder: URL) -> URL {
        folder.appendingPathComponent(track.recoveryFileName)
    }

    /// Prefer the compact AAC track, falling back to the crash-safe CAF only
    /// when AAC cannot be decoded or is materially shorter. The latter covers
    /// a crash that leaves a technically readable but truncated MP4 container.
    static func readableURL(for track: Track, in folder: URL) -> URL? {
        preferredURL(for: track, in: folder, minimumDuration: 0)
    }

    static func transcribableURL(for track: Track, in folder: URL) -> URL? {
        preferredURL(for: track, in: folder,
                     minimumDuration: AudioFileInspector.minimumTranscribableDuration)
    }

    static func duration(for track: Track, in folder: URL) -> TimeInterval? {
        guard let url = readableURL(for: track, in: folder) else { return nil }
        return AudioFileInspector.duration(at: url)
    }

    static func longestDuration(in folder: URL) -> TimeInterval? {
        Track.allCases.compactMap { duration(for: $0, in: folder) }.max()
    }

    /// A normal stop leaves a finalized primary track, so its duplicate CAF can
    /// be removed. If the primary is unreadable, preserving the CAF is a hard
    /// data-safety rule: it may be the user's only recoverable recording.
    static func removeRedundantRecoveryFiles(in folder: URL) {
        for track in Track.allCases {
            let primary = primaryURL(for: track, in: folder)
            guard readableURL(for: track, in: folder) == primary else { continue }
            try? FileManager.default.removeItem(at: recoveryURL(for: track, in: folder))
        }
    }

    private static func preferredURL(for track: Track, in folder: URL,
                                     minimumDuration: TimeInterval) -> URL? {
        let primary = primaryURL(for: track, in: folder)
        let recovery = recoveryURL(for: track, in: folder)
        let primaryDuration = AudioFileInspector.duration(at: primary)
            .flatMap { $0 >= minimumDuration && $0 > 0 ? $0 : nil }
        let recoveryDuration = AudioFileInspector.duration(at: recovery)
            .flatMap { $0 >= minimumDuration && $0 > 0 ? $0 : nil }

        switch (primaryDuration, recoveryDuration) {
        case (.some(let primaryDuration), .some(let recoveryDuration)):
            return recoveryDuration > primaryDuration + completenessTolerance ? recovery : primary
        case (.some, .none):
            return primary
        case (.none, .some):
            return recovery
        case (.none, .none):
            return nil
        }
    }
}
