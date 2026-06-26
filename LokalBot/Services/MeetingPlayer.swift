import Foundation
import AVFoundation

/// Plays a meeting's tracks (mic.m4a + system.m4a) as one: the two files
/// were recorded simultaneously, so playing both from the same offset
/// reproduces the meeting. Click-to-seek from the transcript lands here.
@MainActor
final class MeetingPlayer: NSObject, ObservableObject {

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isLoaded = false
    /// Playback rate (1.0 = normal). AVAudioPlayer honors `enableRate` + `rate`.
    @Published var speed: Float = 1.0 { didSet { applySpeed() } }

    private var players: [AVAudioPlayer] = []
    private var ticker: Timer?

    func load(folder: URL, hasSystemTrack: Bool) {
        stop()
        players = ["mic.m4a", hasSystemTrack ? "system.m4a" : nil]
            .compactMap { $0 }
            .map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .compactMap { try? AVAudioPlayer(contentsOf: $0) }
        for player in players {
            player.delegate = self
            player.enableRate = true
            player.prepareToPlay()
        }
        applySpeed()
        duration = players.map(\.duration).max() ?? 0
        currentTime = 0
        isLoaded = !players.isEmpty
    }

    func playPause() {
        isPlaying ? pause() : play()
    }

    func play(at time: TimeInterval? = nil) {
        guard !players.isEmpty else { return }
        if let time {
            for player in players { player.currentTime = min(time, player.duration) }
            currentTime = time
        }
        // Schedule against a shared device-time anchor so both tracks stay in sync.
        let anchor = (players.first?.deviceCurrentTime ?? 0) + 0.05
        for player in players {
            player.enableRate = true
            player.rate = speed
            player.play(atTime: anchor)
        }
        isPlaying = true
        startTicker()
    }

    /// Push the current `speed` to every player (live rate change).
    private func applySpeed() {
        for player in players where player.enableRate { player.rate = speed }
    }

    func pause() {
        for player in players { player.pause() }
        isPlaying = false
        stopTicker()
    }

    func seek(to time: TimeInterval) {
        let wasPlaying = isPlaying
        pause()
        let clamped = max(0, min(time, duration))
        for player in players { player.currentTime = min(clamped, player.duration) }
        currentTime = clamped
        if wasPlaying { play() }
    }

    func stop() {
        for player in players { player.stop() }
        players = []
        isPlaying = false
        isLoaded = false
        stopTicker()
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let first = self.players.first else { return }
                self.currentTime = first.currentTime
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

extension MeetingPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // The longest track decides when the meeting is over.
            if players.allSatisfy({ !$0.isPlaying }) {
                isPlaying = false
                currentTime = duration
                stopTicker()
            }
        }
    }
}
