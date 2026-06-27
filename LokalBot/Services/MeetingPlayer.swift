import Foundation
import AVFoundation

/// Plays a meeting's tracks as one gain-staged composition. The two source
/// files were recorded simultaneously; `MeetingAudioAsset` mixes them with
/// enough headroom to avoid clipped/phasey voices, while `AVPlayerItem` keeps
/// faster playback pitch-correct.
@MainActor
final class MeetingPlayer: NSObject, ObservableObject {

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isLoaded = false
    /// Playback rate (1.0 = normal). `AVPlayerItem.audioTimePitchAlgorithm`
    /// preserves speech pitch while the rate changes.
    @Published var speed: Float = 1.0 { didSet { applySpeed() } }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var finishObserver: NSObjectProtocol?

    func load(folder: URL, hasSystemTrack: Bool) {
        stop()
        do {
            let prepared = try MeetingAudioAsset.prepare(folder: folder, hasSystemTrack: hasSystemTrack)
            let item = AVPlayerItem(asset: prepared.composition)
            item.audioMix = prepared.audioMix
            item.audioTimePitchAlgorithm = .spectral

            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            self.player = player

            duration = prepared.duration
            currentTime = 0
            isLoaded = duration > 0

            addObservers(player: player, item: item)
        } catch {
            duration = 0
            currentTime = 0
            isLoaded = false
        }
    }

    func playPause() {
        isPlaying ? pause() : play()
    }

    func play(at time: TimeInterval? = nil) {
        guard let player, isLoaded else { return }
        if let time {
            seek(to: time, resumePlayback: true)
            return
        }
        if duration > 0, currentTime >= duration {
            seek(to: 0, resumePlayback: true)
            return
        }
        player.playImmediately(atRate: speed)
        isPlaying = true
    }

    /// Push the current `speed` to every player (live rate change).
    private func applySpeed() {
        guard isPlaying else { return }
        player?.rate = speed
    }

    func pause() {
        guard let player else { return }
        currentTime = CMTimeGetSeconds(player.currentTime())
        player.pause()
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        let wasPlaying = isPlaying
        player?.pause()
        isPlaying = false
        seek(to: time, resumePlayback: wasPlaying)
    }

    func stop() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let finishObserver {
            NotificationCenter.default.removeObserver(finishObserver)
        }
        player?.pause()
        player = nil
        timeObserver = nil
        finishObserver = nil
        isPlaying = false
        isLoaded = false
        currentTime = 0
        duration = 0
    }

    private func seek(to time: TimeInterval, resumePlayback: Bool) {
        guard let player else { return }
        let clamped = max(0, min(time, duration))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = clamped
                if resumePlayback {
                    self.player?.playImmediately(atRate: self.speed)
                    self.isPlaying = true
                }
            }
        }
    }

    private func addObservers(player: AVPlayer, item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.currentTime = min(CMTimeGetSeconds(time), self.duration)
            }
        }

        finishObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.currentTime = self.duration
            }
        }
    }
}
