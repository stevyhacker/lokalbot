import CryptoKit
import XCTest
@testable import LokalBot

@MainActor final class MeetingSpeakerObserverLifecycleTests: XCTestCase {
    private final class SuspendedProvider: MeetingSpeakerObservationProvider {
        var pending: CheckedContinuation<MeetingSpeakerObservationBatch, Never>?
        let requested: XCTestExpectation
        let stopped: XCTestExpectation
        init(requested: XCTestExpectation, stopped: XCTestExpectation) { self.requested = requested; self.stopped = stopped }
        func observe(config: AppSettings, expectedMeetingURL: URL?, capturedBundleID: String, visual: Bool) async -> MeetingSpeakerObservationBatch {
            await withCheckedContinuation { continuation in
                pending = continuation
                requested.fulfill()
            }
        }
        func stop() async { stopped.fulfill() }
        func complete() {
            pending?.resume(returning: .init(sourceKey: "late-source", observations: []))
            pending = nil
        }
    }

    func testStopStartRaceDoesNotPublishLateSourceIntoEitherMeeting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-lifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let first = try storage.createMeetingFolder(title: "First synthetic", appName: "Google Chrome")
        let second = try storage.createMeetingFolder(title: "Second synthetic", appName: "Google Chrome")
        let firstRequest = expectation(description: "first source pending")
        let secondRequest = expectation(description: "second source pending")
        let firstStop = expectation(description: "first provider stopped")
        let secondStop = expectation(description: "second provider stopped")
        let firstProvider = SuspendedProvider(requested: firstRequest, stopped: firstStop)
        let secondProvider = SuspendedProvider(requested: secondRequest, stopped: secondStop)
        var providers = [firstProvider, secondProvider]
        var settings = AppSettings(); settings.identifySpeakersFromVisuals = true
        let identity = MeetingSpeakerIdentityService(storage: storage, settings: { settings }, keyProvider: { SymmetricKey(size: .bits256) })
        let observer = MeetingSpeakerObserver(identity: identity, settings: { settings }, providerFactory: { providers.removeFirst() })
        observer.start(meeting: first, clock: RecordingAudioClock(), capturedBundleID: "com.google.Chrome")
        await fulfillment(of: [firstRequest], timeout: 2)
        observer.start(meeting: second, clock: RecordingAudioClock(), capturedBundleID: "com.google.Chrome")
        await fulfillment(of: [secondRequest], timeout: 2)
        firstProvider.complete()
        observer.stop()
        secondProvider.complete()
        await fulfillment(of: [firstStop, secondStop], timeout: 2)
        let store = try identity.store()
        let old = try await store.evidence(meeting: first, retentionDays: 14)
        let new = try await store.evidence(meeting: second, retentionDays: 14)
        XCTAssertEqual(old?.intervals.count, 0)
        XCTAssertEqual(new?.intervals.count, 0)
        XCTAssertEqual(old?.providerVerified, false)
        XCTAssertEqual(new?.providerVerified, false)
        XCTAssertEqual(observer.state, .off)
    }

    func testChangedAudioAppRejectsTheCaptureSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-source-change-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let meeting = try storage.createMeetingFolder(title: "Synthetic", appName: "Google Chrome")
        let requested = expectation(description: "source pending")
        let stopped = expectation(description: "source stopped")
        let provider = SuspendedProvider(requested: requested, stopped: stopped)
        var settings = AppSettings(); settings.identifySpeakersFromVisuals = true
        let identity = MeetingSpeakerIdentityService(storage: storage, settings: { settings }, keyProvider: { SymmetricKey(size: .bits256) })
        let observer = MeetingSpeakerObserver(identity: identity, settings: { settings }, providerFactory: { provider })
        observer.start(meeting: meeting, clock: RecordingAudioClock(), capturedBundleID: "com.google.Chrome")
        await fulfillment(of: [requested], timeout: 2)
        observer.rejectChangedAudioSource()
        provider.complete()
        await fulfillment(of: [stopped], timeout: 2)
        let evidence = try await identity.store().evidence(meeting: meeting, retentionDays: 14)
        XCTAssertNil(evidence)
        guard case .unavailable = observer.state else { return XCTFail("Changed source was not surfaced") }
    }

    func testDisabledFeatureNeverOpensEvidenceKeyOrProvider() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-disabled-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let meeting = try storage.createMeetingFolder(title: "Synthetic", appName: "Google Chrome")
        let identity = MeetingSpeakerIdentityService(storage: storage, settings: { AppSettings() }, keyProvider: {
            XCTFail("Disabled feature accessed its encryption key")
            return SymmetricKey(size: .bits256)
        })
        let observer = MeetingSpeakerObserver(identity: identity, settings: { AppSettings() }, providerFactory: {
            XCTFail("Disabled feature constructed a provider")
            return GoogleMeetSpeakerObservationProvider()
        })
        observer.start(meeting: meeting, clock: RecordingAudioClock(), capturedBundleID: "com.google.Chrome")
        XCTAssertEqual(observer.state, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.folderURL(in: storage).appendingPathComponent("speaker-evidence").path))
    }
}
