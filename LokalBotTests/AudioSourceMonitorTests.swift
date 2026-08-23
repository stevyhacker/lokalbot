import CoreAudio
import XCTest
@testable import LokalBot

/// `AudioSourceMonitor` detects when an app newly starts producing audio.
/// Pure media/music players (Spotify, Apple Music, …) must be excluded so
/// playing music never becomes a recording candidate, while meeting apps and
/// the browsers that host web meetings stay eligible.
final class AudioSourceMonitorTests: XCTestCase {

    func testMusicAndMediaPlayersAreExcluded() {
        // Streaming music
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.spotify.client"), "Spotify")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.apple.Music"), "Apple Music")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.amazon.music"), "Amazon Music")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.tidal.desktop"), "TIDAL")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.deezer.deezer-desktop"), "Deezer")
        // Local-library / audiophile players
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.swinsian.Swinsian"), "Swinsian")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.foobar2000.mac"), "foobar2000")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.coppertino.Vox"), "VOX")
        // Podcasts & video players
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.apple.podcasts"), "Podcasts")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("org.videolan.vlc"), "VLC")
    }

    func testMeetingAppsAreNotExcluded() {
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("us.zoom.xos"), "Zoom")
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("com.microsoft.teams2"), "Teams")
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("com.apple.FaceTime"), "FaceTime")
    }

    /// Browsers host web meetings (Meet/Jitsi/Whereby), so they must NEVER be
    /// treated as media — otherwise a browser meeting would stop being detected.
    func testBrowsersAreNotExcluded() {
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("com.google.Chrome"), "Chrome")
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("com.apple.Safari"), "Safari")
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("company.thebrowser.Browser"), "Arc")
    }

    func testBrowserAudioHelpersMapToBrowserHost() {
        XCTAssertEqual(MeetingDetector.hostBrowserBundleID(forAudioBundleID: "com.google.Chrome.helper"),
                       "com.google.Chrome")
        XCTAssertEqual(MeetingDetector.hostBrowserBundleID(forAudioBundleID: "com.google.Chrome"),
                       "com.google.Chrome")
        XCTAssertNil(MeetingDetector.hostBrowserBundleID(forAudioBundleID: "com.spotify.client"))
    }

    func testBrowserCapturePrefersRunningHelperOverHostProcess() {
        let host = AudioProcess(id: 100,
                                name: "Google Chrome",
                                bundleID: "com.google.Chrome",
                                objectID: AudioObjectID(100),
                                isRunningOutput: true)
        let helper = AudioProcess(id: 200,
                                  name: "Google Chrome Helper",
                                  bundleID: "com.google.Chrome.helper",
                                  objectID: AudioObjectID(200),
                                  isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Google Chrome",
                                              bundleID: "com.google.Chrome",
                                              pid: host.id)

        XCTAssertEqual(MeetingDetector.bestOutputAudioProcess(for: app, in: [host, helper])?.id,
                       helper.id)
    }

    func testBrowserCaptureKeepsDetectedPidWhenItIsAlreadyHelper() {
        let helper = AudioProcess(id: 200,
                                  name: "Google Chrome Helper",
                                  bundleID: "com.google.Chrome.helper",
                                  objectID: AudioObjectID(200),
                                  isRunningOutput: true)
        let otherHelper = AudioProcess(id: 300,
                                       name: "Google Chrome Helper",
                                       bundleID: "com.google.Chrome.helper",
                                       objectID: AudioObjectID(300),
                                       isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Google Chrome",
                                              bundleID: "com.google.Chrome",
                                              pid: helper.id)

        XCTAssertEqual(MeetingDetector.bestOutputAudioProcess(for: app, in: [otherHelper, helper])?.id,
                       helper.id)
    }

    func testZoomCaptureMapsCptHostAndPrefersItOverTheHost() {
        let host = AudioProcess(id: 100,
                                name: "zoom.us",
                                bundleID: "us.zoom.xos",
                                objectID: AudioObjectID(100),
                                isRunningOutput: true)
        let helper = AudioProcess(id: 200,
                                  name: "CptHost",
                                  bundleID: "us.zoom.CptHost",
                                  objectID: AudioObjectID(200),
                                  isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(
            name: "Zoom", bundleID: "us.zoom.xos", pid: host.id)

        XCTAssertTrue(MeetingDetector.audioBundleID(
            "us.zoom.CptHost", belongsTo: "us.zoom.xos"))
        XCTAssertEqual(
            MeetingDetector.bestOutputAudioProcess(for: app, in: [host, helper])?.id,
            helper.id)
    }

    /// Electron meeting apps (Teams, Slack, Webex) emit call audio from a
    /// helper process exactly as Chromium browsers do, and ``audioBundleID``
    /// already models that `<host>.helper` relationship for every host — not
    /// just the browser/Zoom special cases. The capture lookup must honour it
    /// outside those branches too: when it does not, `hasOutputAudio` is false,
    /// the detector never surfaces the app, and `RecordingController` skips the
    /// process tap entirely — the meeting silently records mic-only.
    func testNativeAppCaptureFallsBackToHelperProcess() {
        let host = AudioProcess(id: 100,
                                name: "Microsoft Teams",
                                bundleID: "com.microsoft.teams2",
                                objectID: AudioObjectID(100),
                                isRunningOutput: false)
        let helper = AudioProcess(id: 200,
                                  name: "Microsoft Teams Helper",
                                  bundleID: "com.microsoft.teams2.helper",
                                  objectID: AudioObjectID(200),
                                  isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: host.id)

        XCTAssertTrue(MeetingDetector.audioBundleID(
            "com.microsoft.teams2.helper", belongsTo: "com.microsoft.teams2"))
        XCTAssertEqual(MeetingDetector.bestOutputAudioProcess(for: app, in: [host, helper])?.id,
                       helper.id)
    }

    /// Measured on a real Teams call: audio comes from `<host>.helper` (the
    /// WebView) *and* `<host>.modulehost`, and the WebView is running output
    /// only part of the time. Matching just `.helper` therefore still loses the
    /// tap most of the time, so the whole `<host>.` namespace has to count —
    /// the same rule the `us.zoom.xos.` branch already applies.
    func testNativeAppCaptureAcceptsAnyBundleInTheHostNamespace() {
        XCTAssertTrue(MeetingDetector.audioBundleID(
            "com.microsoft.teams2.modulehost", belongsTo: "com.microsoft.teams2"))

        let host = AudioProcess(id: 100,
                                name: "Microsoft Teams",
                                bundleID: "com.microsoft.teams2",
                                objectID: AudioObjectID(100),
                                isRunningOutput: false)
        let moduleHost = AudioProcess(id: 300,
                                      name: "Microsoft Teams ModuleHost",
                                      bundleID: "com.microsoft.teams2.modulehost",
                                      objectID: AudioObjectID(300),
                                      isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: host.id)

        XCTAssertEqual(
            MeetingDetector.bestOutputAudioProcess(for: app, in: [host, moduleHost])?.id,
            moduleHost.id)
    }

    /// Measured on a real Teams call: `translatePIDToProcessObject` fails for
    /// the Teams host PID because that process owns no Core Audio object. When
    /// the meeting is momentarily quiet no sibling is `isRunningOutput` either,
    /// so a capture lookup that requires current output resolves to nothing and
    /// the tap is refused. Capture must therefore accept a silent-but-present
    /// process in the namespace — the tap records once audio starts.
    func testCaptureTargetFallsBackToASilentProcessInTheNamespace() {
        let host = AudioProcess(id: 100,
                                name: "Microsoft Teams",
                                bundleID: "com.microsoft.teams2",
                                objectID: AudioObjectID(100),
                                isRunningOutput: false)
        let quietModuleHost = AudioProcess(id: 300,
                                           name: "Microsoft Teams ModuleHost",
                                           bundleID: "com.microsoft.teams2.modulehost",
                                           objectID: AudioObjectID(300),
                                           isRunningOutput: false)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: host.id)

        // Detection correctly reports "not producing output right now"...
        XCTAssertNil(MeetingDetector.bestOutputAudioProcess(
            for: app, in: [host, quietModuleHost]))
        // ...but capture still has somewhere to attach.
        XCTAssertEqual(
            MeetingDetector.captureTargetProcess(for: app, in: [host, quietModuleHost])?.id,
            quietModuleHost.id)
    }

    /// A process that *is* producing output still wins over a silent sibling.
    func testCaptureTargetPrefersTheProcessThatIsActuallyEmitting() {
        let quiet = AudioProcess(id: 300,
                                 name: "Microsoft Teams ModuleHost",
                                 bundleID: "com.microsoft.teams2.modulehost",
                                 objectID: AudioObjectID(300),
                                 isRunningOutput: false)
        let emitting = AudioProcess(id: 400,
                                    name: "Microsoft Teams WebView",
                                    bundleID: "com.microsoft.teams2.helper",
                                    objectID: AudioObjectID(400),
                                    isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: 100)

        XCTAssertEqual(
            MeetingDetector.captureTargetProcess(for: app, in: [quiet, emitting])?.id,
            emitting.id)
    }

    /// Capture must not attach to an unrelated app just because nothing of the
    /// meeting app is running.
    func testCaptureTargetIgnoresUnrelatedProcesses() {
        let unrelated = AudioProcess(id: 500,
                                     name: "Music",
                                     bundleID: "com.apple.Music",
                                     objectID: AudioObjectID(500),
                                     isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: 100)

        XCTAssertNil(MeetingDetector.captureTargetProcess(for: app, in: [unrelated]))
    }

    /// The namespace rule must not swallow a *different* app whose bundle id
    /// merely starts with the same characters.
    func testNamespaceMatchDoesNotSpanUnrelatedBundles() {
        XCTAssertFalse(MeetingDetector.audioBundleID(
            "com.microsoft.teams2evil", belongsTo: "com.microsoft.teams2"))
        XCTAssertFalse(MeetingDetector.audioBundleID(
            "com.microsoft.teamsother", belongsTo: "com.microsoft.teams2"))
    }

    /// The helper fallback must stay a *fallback*: when the host process itself
    /// is producing output it remains the capture target, so apps that work
    /// today are unaffected.
    func testNativeAppCapturePrefersHostWhenItIsProducingOutput() {
        let host = AudioProcess(id: 100,
                                name: "Microsoft Teams",
                                bundleID: "com.microsoft.teams2",
                                objectID: AudioObjectID(100),
                                isRunningOutput: true)
        let helper = AudioProcess(id: 200,
                                  name: "Microsoft Teams Helper",
                                  bundleID: "com.microsoft.teams2.helper",
                                  objectID: AudioObjectID(200),
                                  isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: host.id)

        XCTAssertEqual(MeetingDetector.bestOutputAudioProcess(for: app, in: [host, helper])?.id,
                       host.id)
    }

    /// Unknown apps stay eligible so a genuinely-new meeting tool is still
    /// surfaced via the monitor's fallback candidate path.
    func testUnknownAppIsNotExcluded() {
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("com.example.SomeNewMeetingApp"))
    }
}
