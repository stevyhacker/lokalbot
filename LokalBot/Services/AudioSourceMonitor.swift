import AppKit
import AudioToolbox
import Foundation

/// Polls Core Audio's process list for new audio-producing apps and surfaces
/// them as candidates to start recording. A second detection signal next to
/// `MeetingDetector`'s "is the mic in use" — catches the cases the mic
/// signal misses (Zoom call with mic muted, a meeting in a browser tab the
/// user opened *before* unmuting). Pattern from Seminarly's
/// `AudioSourceMonitor`, adapted to LokalBot's coordinator.
@MainActor
final class AudioSourceMonitor: ObservableObject {

    /// The most recently-detected new audio source the user has neither
    /// dismissed nor acted on. UI binds to this to show a "Record …?" banner.
    @Published private(set) var detectedProcess: AudioProcess?

    /// Set by `AppState` while a recording is in flight — suppresses new
    /// detections (we don't want to nag the user during a recording, and the
    /// app we're recording is itself running output).
    var isRecordingActive = false {
        didSet {
            if isRecordingActive {
                detectedProcess = nil
                bannerDismissTask?.cancel()
                bannerDismissTask = nil
            }
        }
    }

    /// Bundle IDs of conferencing/meeting apps prioritized over generic audio
    /// sources (so a Spotify track that started 200 ms before Zoom didn't win
    /// the race). The native list mirrors `MeetingDetector.knownApps` plus
    /// the browser set, augmented with a few extras from Seminarly's list.
    private static let meetingBundleIDs: Set<String> = [
        "us.zoom.xos", "us.zoom.CptHost",
        "com.microsoft.teams", "com.microsoft.teams2",
        "com.apple.FaceTime",
        "com.webex.meetingmanager", "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser",
        "com.operasoftware.Opera", "company.thebrowser.Browser",
        "com.loom.desktop", "com.pop.pop.app", "com.riverside.app",
    ]

    /// Bundle IDs whose audio is uninteresting — our own app and a few system
    /// processes that emit short blips Core Audio still reports as "running".
    private static let ignoredBundleIDs: Set<String> = [
        "com.dotenv.LokalBotV3",
        "com.apple.controlcenter",
        "com.apple.SystemSounds",
        "com.apple.finder",
        "com.apple.notificationcenterui",
    ]

    /// Pure media/music players. They emit continuous output but are never
    /// meetings, so — unlike an unknown app — they must not surface a
    /// "Record …?" suggestion. Browsers are intentionally absent: a web
    /// meeting (Meet/Jitsi/Whereby) runs inside one, so those stay recordable.
    nonisolated static let mediaBundleIDs: Set<String> = [
        // Streaming music
        "com.spotify.client",          // Spotify
        "com.apple.Music",             // Apple Music
        "com.apple.iTunes",            // iTunes (legacy)
        "com.amazon.music",            // Amazon Music
        "com.tidal.desktop",           // TIDAL
        "com.deezer.deezer-desktop",   // Deezer
        "com.netease.163music",        // NetEase Cloud Music
        "com.tencent.QQMusicMac",      // QQ Music
        // Local-library / audiophile players
        "com.swinsian.Swinsian",       // Swinsian
        "com.audirvana.Audirvana",     // Audirvana
        "com.foobar2000.mac",          // foobar2000
        "com.roon.Roon",               // Roon
        "com.coppertino.Vox",          // VOX
        "tv.plex.plexamp",             // Plexamp
        // Podcasts & video players (also never meetings)
        "com.apple.podcasts",          // Apple Podcasts
        "com.apple.TV",                // Apple TV
        "com.apple.QuickTimePlayerX",  // QuickTime Player
        "org.videolan.vlc",            // VLC
        "com.colliderli.iina",         // IINA
    ]

    /// Whether `bundleID` is a pure media player that should never trigger a
    /// recording suggestion. See ``mediaBundleIDs``.
    nonisolated static func isMediaPlayer(_ bundleID: String) -> Bool {
        mediaBundleIDs.contains(bundleID)
    }

    private static let pollInterval: TimeInterval = 3.0
    private static let bannerTimeout: TimeInterval = 20.0

    private var pollTimer: Timer?
    /// AudioObjectIDs already running output the last time we polled. A new
    /// detection fires only on a not-running → running transition.
    private var knownActiveObjectIDs: Set<AudioObjectID> = []
    /// Bundle IDs the user dismissed in this session — never re-suggest
    /// until `reseed()` (typically after a recording ends).
    private var dismissedBundleIDs: Set<String> = []
    private var bannerDismissTask: Task<Void, Never>?

    func start() {
        stop()
        seedCurrentState()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
    }

    func dismiss() {
        if let process = detectedProcess, let bundleID = process.bundleID {
            dismissedBundleIDs.insert(bundleID)
        }
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        detectedProcess = nil
    }

    /// Consumes the current candidate (caller is starting a recording on it).
    @discardableResult
    func accept() -> AudioProcess? {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        let process = detectedProcess
        detectedProcess = nil
        return process
    }

    /// Forget dismissals and re-seed against the *current* audio state. Call
    /// after a recording ends so apps that started playing audio mid-meeting
    /// don't immediately trigger a banner.
    func reseed() {
        dismissedBundleIDs.removeAll()
        seedCurrentState()
    }

    // MARK: - Private

    private func seedCurrentState() {
        let processes = (try? CoreAudioUtils.listAudioProcesses()) ?? []
        knownActiveObjectIDs = Set(processes.filter(\.isRunningOutput).map(\.objectID))
    }

    private func poll() {
        guard !isRecordingActive else { return }
        let processes = (try? CoreAudioUtils.listAudioProcesses()) ?? []
        let active = processes.filter(\.isRunningOutput)
        let activeIDs = Set(active.map(\.objectID))

        let newlyActiveIDs = activeIDs.subtracting(knownActiveObjectIDs)
        knownActiveObjectIDs = activeIDs

        guard !newlyActiveIDs.isEmpty, detectedProcess == nil else { return }

        let candidates = active.filter { process in
            guard newlyActiveIDs.contains(process.objectID) else { return false }
            if let bundleID = process.bundleID {
                if Self.ignoredBundleIDs.contains(bundleID) { return false }
                if Self.isMediaPlayer(bundleID) { return false }
                if dismissedBundleIDs.contains(bundleID) { return false }
            }
            return true
        }

        let meetingApp = candidates.first { process in
            guard let bundleID = process.bundleID else { return false }
            return Self.meetingBundleIDs.contains(bundleID)
        }

        if let best = meetingApp ?? candidates.first {
            detectedProcess = best
            scheduleBannerDismiss()
        }
    }

    private func scheduleBannerDismiss() {
        bannerDismissTask?.cancel()
        bannerDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.bannerTimeout))
            guard !Task.isCancelled else { return }
            detectedProcess = nil
        }
    }
}
