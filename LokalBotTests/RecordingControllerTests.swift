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
            onError: { message in
                if let message { XCTFail("unexpected error surfaced: \(message)") }
            },
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

    /// A zero-buffer attachment still takes the current PID out of the running.
    /// `SystemAudioTapLedger` now holds that decision, because the exclusion has
    /// to outlive the tick that made it — see the ledger tests below.
    func testZeroBufferAttachmentExcludesCurrentPIDFromRecovery() {
        var ledger = SystemAudioTapLedger()
        ledger.attached(to: 200, audibleDuration: 0)
        ledger.retire(200)
        XCTAssertEqual(ledger.retiredPIDs, [200])

        XCTAssertTrue(SystemAudioRecoveryCandidatePolicy.shouldRetrySamePID(
            framesSinceAttach: 0,
            audibleDuration: 30,
            minimumAudibleDuration: 1))
        XCTAssertFalse(SystemAudioRecoveryCandidatePolicy.shouldRetrySamePID(
            framesSinceAttach: 1,
            audibleDuration: 30,
            minimumAudibleDuration: 1))
    }

    func testSamePIDRetryBudgetIsConsumedBeforeTheAttemptOutcome() {
        var budget = SystemAudioSamePIDRetryBudget()

        XCTAssertTrue(budget.beginRetry())
        XCTAssertEqual(budget.attempts, 1)
        XCTAssertTrue(budget.beginRetry())
        XCTAssertEqual(budget.attempts, SystemAudioSamePIDRetryBudget.maximumAttempts)
        XCTAssertFalse(budget.beginRetry(), "failed reattachments must remain bounded")

        budget.reset()
        XCTAssertTrue(budget.canRetry)
        XCTAssertEqual(budget.attempts, 0)
    }

    // MARK: - Silent system audio advisory

    /// The advisory exists for a tap attached to a process that never emits,
    /// so a capture that stayed silent must keep it. Anything that did deliver
    /// a usable track takes it back — including at `stop()`, since the watchdog
    /// tick that would otherwise notice may never come.
    func testWithdrawsSilentSystemAudioWarningOnlyOnceATrackExists() {
        let audible = AudioFileInspector.minimumTranscribableDuration

        XCTAssertTrue(RecordingController.shouldWithdrawSilentSystemAudioWarning(
            hasWarned: true, audibleDuration: audible))
        XCTAssertTrue(RecordingController.shouldWithdrawSilentSystemAudioWarning(
            hasWarned: true, audibleDuration: audible * 10))

        XCTAssertFalse(RecordingController.shouldWithdrawSilentSystemAudioWarning(
            hasWarned: true, audibleDuration: 0))
        XCTAssertFalse(RecordingController.shouldWithdrawSilentSystemAudioWarning(
            hasWarned: true, audibleDuration: audible / 2))

        // Nothing to take back when nothing was ever shown.
        XCTAssertFalse(RecordingController.shouldWithdrawSilentSystemAudioWarning(
            hasWarned: false, audibleDuration: audible * 10))
    }

    /// A reattach withdraws the warning for the failed target and leaves the
    /// replacement eligible to warn again if it also stays silent.
    func testSilentSystemAudioWarningWarnReattachWarnTransition() {
        var warning = SilentSystemAudioWarningState()

        XCTAssertTrue(warning.present())
        XCTAssertTrue(warning.isPresented)
        XCTAssertFalse(warning.present(), "the same target must warn only once")

        XCTAssertTrue(warning.withdraw(), "reattach must withdraw the visible warning")
        XCTAssertFalse(warning.isPresented)
        XCTAssertFalse(warning.withdraw(), "withdrawal must be idempotent")

        XCTAssertTrue(warning.present(), "a silent replacement may surface a fresh warning")
    }

    /// A genuinely silent capture keeps its advisory after stop, but the next
    /// capture start must withdraw it so an old banner cannot outlive the state
    /// that originally presented it.
    func testSilentSystemAudioWarningSurvivesStopUntilNextCaptureStarts() {
        var warning = SilentSystemAudioWarningState()

        XCTAssertTrue(warning.present())
        XCTAssertTrue(warning.isPresented, "stop deliberately preserves a true warning")
        XCTAssertTrue(warning.withdraw(), "the next capture start retires the old warning")
        XCTAssertFalse(warning.isPresented)
    }

    // MARK: - System audio tap ledger

    private var minimumAudible: TimeInterval { AudioFileInspector.minimumTranscribableDuration }

    /// `CaptureHealth.audibleDuration` counts the whole file, so a tap that
    /// inherits a healthy total must not inherit the standing that goes with
    /// it — otherwise the first process the watchdog moves to counts as proven
    /// before it has written a sample, and earns the long grace for nothing.
    func testProofIsAttributedToTheTapThatEarnedIt() {
        var ledger = SystemAudioTapLedger()
        ledger.attached(to: 8430, audibleDuration: 0)
        ledger.observe(pid: 8430, audibleDuration: 132.76, minimum: minimumAudible)
        XCTAssertEqual(ledger.provenPID, 8430)

        // Moving to a sibling carries the session total across untouched.
        ledger.attached(to: 8449, audibleDuration: 132.76)
        ledger.observe(pid: 8449, audibleDuration: 132.76, minimum: minimumAudible)
        XCTAssertEqual(ledger.provenPID, 8430)

        // Only audio this tap wrote itself transfers the standing.
        ledger.observe(pid: 8449, audibleDuration: 140, minimum: minimumAudible)
        XCTAssertEqual(ledger.provenPID, 8449)
    }

    /// Eight seconds of silence is a pause between two sentences. A tap that has
    /// written audible audio is not the reason for it and stays put; one that
    /// has proved nothing is still worth moving that quickly.
    func testProvenTapWaitsOutAnOrdinaryPause() {
        var ledger = SystemAudioTapLedger()
        ledger.attached(to: 8430, audibleDuration: 0)
        XCTAssertEqual(ledger.silenceGrace(for: 8430, ordinary: 8, proven: 90), 8)

        ledger.observe(pid: 8430, audibleDuration: 12, minimum: minimumAudible)
        XCTAssertEqual(ledger.silenceGrace(for: 8430, ordinary: 8, proven: 90), 90)
        // The patience is for that tap alone, not for silence in general.
        XCTAssertEqual(ledger.silenceGrace(for: 8449, ordinary: 8, proven: 90), 8)
    }

    /// Replays the flap in the log of 2026-08-25 10:36–10:57: modulehost carried
    /// the call, a helper delivered nothing, and the watchdog swapped between
    /// them every 10–15 s because each lookup was free to hand back the empty
    /// one. Excluding only the tap in hand cannot stop that; the exclusion has
    /// to persist.
    func testARetiredTapIsNeverHandedBack() {
        var ledger = SystemAudioTapLedger()
        ledger.attached(to: 8430, audibleDuration: 0)
        ledger.observe(pid: 8430, audibleDuration: 132.76, minimum: minimumAudible)

        // One bounce onto the helper, which delivers not a single buffer.
        ledger.attached(to: 8449, audibleDuration: 132.76)
        ledger.retire(8449)
        XCTAssertEqual(ledger.retiredPIDs, [8449])
        XCTAssertEqual(ledger.provenPID, 8430)

        // Back on modulehost, and the helper stays out of the running.
        ledger.attached(to: 8430, audibleDuration: 132.76)
        XCTAssertEqual(ledger.retiredPIDs, [8449])
    }

    /// A PID that proved itself earlier and now delivers nothing has stopped
    /// being the answer; standing follows the evidence in both directions.
    func testRetiringClearsStandingAndAttachingRestoresEligibility() {
        var ledger = SystemAudioTapLedger()
        ledger.attached(to: 8430, audibleDuration: 0)
        ledger.observe(pid: 8430, audibleDuration: 20, minimum: minimumAudible)
        ledger.retire(8430)
        XCTAssertNil(ledger.provenPID)
        XCTAssertEqual(ledger.silenceGrace(for: 8430, ordinary: 8, proven: 90), 8)

        // Teams reuses the process; a fresh attachment gets a fresh hearing.
        ledger.attached(to: 8430, audibleDuration: 20)
        XCTAssertTrue(ledger.retiredPIDs.isEmpty)
    }

    /// Each recording starts with no knowledge of the last one's processes.
    func testLedgerResetForgetsEverything() {
        var ledger = SystemAudioTapLedger()
        ledger.attached(to: 8430, audibleDuration: 0)
        ledger.observe(pid: 8430, audibleDuration: 20, minimum: minimumAudible)
        ledger.retire(8449)
        ledger.reset()
        XCTAssertEqual(ledger, SystemAudioTapLedger())
        XCTAssertNil(ledger.provenPID)
        XCTAssertTrue(ledger.retiredPIDs.isEmpty)
    }
}
