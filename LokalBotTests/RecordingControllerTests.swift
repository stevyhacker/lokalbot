import XCTest
@testable import LokalBot

/// Construction and pure-state coverage for the recording lifecycle owner.
/// The audio path itself needs real devices and TCC grants, so these tests
/// stay on the side of the controller that runs before any capture starts:
/// initial state, timer formatting, idle health reporting, and idle stop.
@MainActor
final class RecordingControllerTests: XCTestCase {

    private func makeController() -> RecordingController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-controller-\(UUID().uuidString)",
                                    isDirectory: true)
        let storage = StorageManager(rootURL: root)
        return RecordingController(
            storage: storage,
            settingsStore: SettingsStore(),
            audioMonitor: AudioSourceMonitor(),
            pipeline: ProcessingPipeline(storage: storage, settings: { AppSettings() }),
            isInteractive: { false },
            onError: { XCTFail("unexpected error surfaced: \($0)") },
            onMeetingFinished: { _ in XCTFail("no meeting should finish") })
    }

    private var teamsApp: MeetingDetector.DetectedApp {
        MeetingDetector.DetectedApp(
            name: "Teams",
            bundleID: "com.microsoft.teams2",
            pid: 100)
    }

    func testStartsIdleWithZeroElapsedTimer() {
        let controller = makeController()

        XCTAssertFalse(controller.isRecording)
        XCTAssertFalse(controller.isStarting)
        XCTAssertNil(controller.currentMeeting)
        XCTAssertEqual(controller.elapsed, 0)
        XCTAssertEqual(controller.menuBarTimer, "00:00")
    }

    func testIdleMemoryHealthSnapshotReportsIdleRecorders() {
        let snapshot = makeController().memoryHealthSnapshot()

        XCTAssertFalse(snapshot.isRecording)
        XCTAssertEqual(snapshot.microphoneStatus, "Idle")
        XCTAssertEqual(snapshot.systemAudioStatus, "Idle")
        XCTAssertEqual(snapshot.microphoneDroppedBuffers, 0)
        XCTAssertEqual(snapshot.systemAudioDroppedBuffers, 0)
        XCTAssertNil(snapshot.lastRecoveryAt)
    }

    /// A stray stop (menu bar action racing a finished meeting) must be a
    /// no-op, not a crash or a phantom meeting.
    func testStopWhileIdleIsANoOp() {
        let controller = makeController()

        controller.stop()

        XCTAssertFalse(controller.isRecording)
        XCTAssertNil(controller.currentMeeting)
    }

    func testPrepareForTerminationFromIdleKeepsControllerIdle() {
        let controller = makeController()

        controller.prepareForTermination()

        XCTAssertFalse(controller.isRecording)
        XCTAssertNil(controller.currentMeeting)
    }

    func testMicrophoneOnlyPolicyNeverResolvesASystemAudioApp() {
        var fallbackWasCalled = false

        let app = RecordingSystemAudioPolicy.microphoneOnly.captureApp(
            detectedApp: teamsApp,
            fallback: {
                fallbackWasCalled = true
                return teamsApp
            })

        XCTAssertNil(app)
        XCTAssertFalse(fallbackWasCalled)
        XCTAssertEqual(HeadlessCommandRunner.recordSystemAudioPolicy, .microphoneOnly)
    }

    func testMeetingAudioPolicyUsesFallbackOnlyWhenNoAppWasDetected() {
        var fallbackCalls = 0
        let policy = RecordingSystemAudioPolicy.meetingAppWhenAvailable

        XCTAssertEqual(policy.captureApp(
            detectedApp: teamsApp,
            fallback: {
                fallbackCalls += 1
                return nil
            }), teamsApp)
        XCTAssertEqual(fallbackCalls, 0)

        XCTAssertEqual(policy.captureApp(
            detectedApp: nil,
            fallback: {
                fallbackCalls += 1
                return teamsApp
            }), teamsApp)
        XCTAssertEqual(fallbackCalls, 1)
    }

    func testZeroBufferAttachmentExcludesCurrentPIDFromRecovery() {
        XCTAssertEqual(SystemAudioRecoveryCandidatePolicy.excludedPID(
            currentPID: 200,
            framesSinceAttach: 0), 200)
        XCTAssertNil(SystemAudioRecoveryCandidatePolicy.excludedPID(
            currentPID: 200,
            framesSinceAttach: 1))
        XCTAssertTrue(SystemAudioRecoveryCandidatePolicy.shouldRetrySamePID(
            framesSinceAttach: 0,
            audibleDuration: 30,
            minimumAudibleDuration: 1))
        XCTAssertFalse(SystemAudioRecoveryCandidatePolicy.shouldRetrySamePID(
            framesSinceAttach: 1,
            audibleDuration: 30,
            minimumAudibleDuration: 1))
    }
}
