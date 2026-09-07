import AudioToolbox
import XCTest
@testable import LokalBot

final class MeetingSpeakerObservationTests: XCTestCase {
    private func batch(time: Double, name: String = "Alex", reference: String = "alex", epoch: String = "grid", source: String = "meet") -> MeetingSpeakerObservationBatch {
        .init(sourceKey: source, observations: [.init(reference: reference, displayName: name,
            layoutEpoch: epoch, hostStart: time, hostEnd: time + 0.02, active: true)])
    }
    private func clock() -> RecordingAudioClock {
        let clock = RecordingAudioClock()
        clock.record(hostTime: AudioConvertNanosToHostTime(100_000_000_000), valid: true,
            startFrame: 0, frames: 48_000 * 60, sampleRate: 48_000)
        return clock
    }
    func testTwoStableObservationsEstablishAudioClockCoverage() throws {
        var accumulator = SpeakerObservationAccumulator()
        let clock = clock()
        XCTAssertNil(accumulator.consume(batch(time: 100), clock: clock))
        let interval = try XCTUnwrap(accumulator.consume(batch(time: 100.5), clock: clock))
        XCTAssertEqual(interval.range.start, 0.02, accuracy: 0.00001)
        XCTAssertEqual(interval.range.end, 0.5, accuracy: 0.00001)
    }
    func testGapsLayoutsSourcesAndStaleFramesNeverExtendThePriorSpeaker() {
        let changes = [batch(time: 102), batch(time: 100.5, epoch: "reordered"), batch(time: 100.5, source: "different-tab"), batch(time: 100)]
        for changed in changes {
            var accumulator = SpeakerObservationAccumulator()
            let clock = clock()
            _ = accumulator.consume(batch(time: 100), clock: clock)
            XCTAssertNil(accumulator.consume(changed, clock: clock))
        }
    }
    func testMultipleActiveDuplicateMutedAndSelfAreAmbiguous() {
        var multiple = batch(time: 100.5)
        multiple.observations += batch(time: 100.5, name: "Sam", reference: "sam").observations
        var duplicate = batch(time: 100.5); duplicate.observations[0].unique = false
        var muted = batch(time: 100.5); muted.observations[0].muted = true
        var local = batch(time: 100.5); local.observations[0].isSelf = true
        var missing = batch(time: 100.5); missing.reason = "source timeout"
        for ambiguous in [multiple, duplicate, muted, local, missing] {
            var accumulator = SpeakerObservationAccumulator()
            let clock = clock()
            _ = accumulator.consume(batch(time: 100), clock: clock)
            XCTAssertNil(accumulator.consume(ambiguous, clock: clock))
            XCTAssertNil(accumulator.consume(batch(time: 101), clock: clock))
        }
    }
    func testExactMeetOriginAndMeetingAssociationAreRequired() {
        XCTAssertEqual(GoogleMeetSpeakerObservationProvider.meetURL("https://meet.google.com/abc-defg-hij?authuser=0"), "https://meet.google.com/abc-defg-hij")
        for bad in ["http://meet.google.com/abc-defg-hij", "https://meet.google.com.evil.test/abc-defg-hij", "https://meet.google.com/landing", "https://evil@meet.google.com/abc-defg-hij"] {
            XCTAssertNil(GoogleMeetSpeakerObservationProvider.meetURL(bad))
        }
        var snapshot = MeetingParticipantSnapshot(processID: 1, title: "Synthetic Meet", url: "https://meet.google.com/abc-defg-hij",
            windowFrame: .init(x: 0, y: 0, width: 1000, height: 700), tiles: [], hostStart: 100, hostEnd: 100.1)
        var config = AppSettings()
        XCTAssertTrue(GoogleMeetSpeakerObservationProvider.sourceAllowed(snapshot: snapshot, config: config, expectedURL: snapshot.url))
        XCTAssertFalse(GoogleMeetSpeakerObservationProvider.sourceAllowed(snapshot: snapshot, config: config, expectedURL: "https://meet.google.com/xyz-uvwx-rst"))
        config.excludedScreenDomains = "meet.google.com"
        XCTAssertFalse(GoogleMeetSpeakerObservationProvider.sourceAllowed(snapshot: snapshot, config: config, expectedURL: nil))
        config.excludedScreenDomains = ""
        snapshot.title = "Meet - Incognito"
        XCTAssertFalse(GoogleMeetSpeakerObservationProvider.sourceAllowed(snapshot: snapshot, config: config, expectedURL: nil))
        snapshot.title = "Meet"; snapshot.hostEnd = 101
        XCTAssertFalse(GoogleMeetSpeakerObservationProvider.sourceAllowed(snapshot: snapshot, config: config, expectedURL: nil))
    }
    func testOnlyNamedParticipantContainersAreAcceptedByTheAdapterContract() {
        XCTAssertEqual(MeetingParticipantAccessibilityReader.tileName(description: "Alex's tile"), "Alex")
        XCTAssertEqual(MeetingParticipantAccessibilityReader.tileName(description: "Sam’s video"), "Sam")
        for invalid in ["Alex is presenting", "Pinned Alex", "Quarterly report", "alex@example.com's tile", "You's tile"] {
            XCTAssertNil(MeetingParticipantAccessibilityReader.tileName(description: invalid))
        }
    }
    func testNewSettingsDecodeOffAndRemainIndependentOfDayMemory() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.identifySpeakersFromVisuals)
        XCTAssertFalse(legacy.rememberSpeakersOnMac)
        var settings = legacy
        settings.identifySpeakersFromVisuals = true
        settings.rememberSpeakersOnMac = true
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restored.identifySpeakersFromVisuals)
        XCTAssertTrue(restored.rememberSpeakersOnMac)
        XCTAssertEqual(restored.screenshotsEnabled, legacy.screenshotsEnabled)
        XCTAssertEqual(restored.meetingVisualContextEnabled, legacy.meetingVisualContextEnabled)
        XCTAssertEqual(restored.screenContextCaptureMode, legacy.screenContextCaptureMode)
    }
}
