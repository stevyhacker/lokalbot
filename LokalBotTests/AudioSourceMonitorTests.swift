import XCTest
@testable import LokalBotV3

/// `AudioSourceMonitor` surfaces a "Record …?" suggestion when an app newly
/// starts producing audio. Pure media/music players (Spotify, Apple Music, …)
/// must be excluded so playing music never prompts to record — while meeting
/// apps and the browsers that host web meetings stay eligible.
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

    /// Unknown apps stay eligible so a genuinely-new meeting tool is still
    /// surfaced via the monitor's fallback candidate path.
    func testUnknownAppIsNotExcluded() {
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("com.example.SomeNewMeetingApp"))
    }
}
