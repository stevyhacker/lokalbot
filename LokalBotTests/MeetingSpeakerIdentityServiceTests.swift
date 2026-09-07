import CryptoKit
import XCTest
@testable import LokalBot

@MainActor final class MeetingSpeakerIdentityServiceTests: XCTestCase {
    private var root: URL!
    private var storage: StorageManager!
    private var service: MeetingSpeakerIdentityService!
    private var settings: AppSettings!
    private var key: SymmetricKey!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-service-\(UUID())")
        storage = StorageManager(rootURL: root)
        settings = AppSettings()
        settings.identifySpeakersFromVisuals = true
        settings.rememberSpeakersOnMac = true
        key = SymmetricKey(size: .bits256)
        service = MeetingSpeakerIdentityService(storage: storage, settings: { [unowned self] in settings }, keyProvider: { [unowned self] in key })
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func fixture(visual: Bool) async throws -> (Meeting, URL, Transcript, [SpeakerAudioTurn], [SpeakerVoiceSample]) {
        let meeting = try storage.createMeetingFolder(title: "Staged rule fixture", appName: "Google Chrome")
        let audioURL = meeting.folderURL(in: storage).appendingPathComponent("fixture-audio.bin")
        // Digest fixture only. No synthetic vector/byte fixture is presented as
        // an audio-recognition accuracy test or a real provider capture.
        try Data("same audio content for digest and identity rules".utf8).write(to: audioURL)
        let turns: [SpeakerAudioTurn] = (0..<4).map { index in
            .init(speaker: "them", range: .init(start: Double(index * 20), end: Double(index * 20 + 10)))
        }
        let transcript = Transcript(segments: turns.map {
            .init(start: $0.range.start, end: $0.range.end, speaker: "them", text: "Synthetic speech turn.", confidence: nil)
        }, engine: "test")
        var vector = [Float](repeating: 0, count: 256); vector[0] = 1
        let samples = turns.map { SpeakerVoiceSample(speaker: "them", range: $0.range, vector: vector) }
        let store = try service.store()
        let generation = UUID()
        try await store.begin(.init(meetingID: meeting.id, generation: generation), meeting: meeting)
        try await store.verifyProvider(meeting: meeting, generation: generation)
        if visual {
            try await store.append(turns.map { .init(participantReference: "alex", displayName: "Alex",
                range: $0.range, uncertainty: 0.1, layoutEpoch: "grid") }, meeting: meeting, generation: generation)
        }
        try await store.seal(meeting: meeting, generation: generation, failed: false)
        return (meeting, audioURL, transcript, turns, samples)
    }

    func testAutomaticNamingDoesNotTrainProfilesAndCorrectionSurvivesReprocessing() async throws {
        let (meeting, audio, transcript, turns, samples) = try await fixture(visual: true)
        let automatic = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        XCTAssertEqual(automatic.speakerAliases["them"], "Alex")
        XCTAssertEqual(automatic.segments, transcript.segments)
        let profiles = try await service.profiles()
        XCTAssertTrue(profiles.isEmpty)
        let state = try await service.state(for: meeting)
        let corrected = try await service.choose(.init(label: "them", name: "Sam", remember: false,
            expectedRevision: state.revision), meeting: meeting, transcript: automatic)
        XCTAssertEqual(corrected.speakerAliases["them"], "Sam")
        let again = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        XCTAssertEqual(again.speakerAliases["them"], "Sam")
        XCTAssertEqual(service.applyingLatestDecision(to: automatic, meetingID: meeting.id).speakerAliases["them"], "Sam")
    }

    func testResetSuppressesReapplicationUntilExplicitResume() async throws {
        let (meeting, audio, transcript, turns, samples) = try await fixture(visual: true)
        let automatic = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        let reset = try await service.choose(.init(label: "them", action: .reset), meeting: meeting, transcript: automatic)
        XCTAssertNil(reset.speakerAliases["them"])
        let again = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        XCTAssertNil(again.speakerAliases["them"])
        let resumed = try await service.choose(.init(label: "them", action: .resume), meeting: meeting, transcript: again)
        XCTAssertEqual(resumed.speakerAliases["them"], "Alex")
    }

    func testConfirmedProfileCanNameLaterMeetingWithoutVisualEvidence() async throws {
        let (first, audio, transcript, turns, samples) = try await fixture(visual: true)
        let automatic = await service.process(transcript: transcript, meeting: first, turns: turns, samples: samples, audioURL: audio)
        _ = try await service.choose(.init(label: "them", name: "Alex", remember: true), meeting: first, transcript: automatic)
        let before = try await service.profiles()
        XCTAssertEqual(before.count, 1)
        let (second, secondAudio, secondTranscript, secondTurns, secondSamples) = try await fixture(visual: false)
        settings.identifySpeakersFromVisuals = false
        let recognized = await service.process(transcript: secondTranscript, meeting: second,
            turns: secondTurns, samples: secondSamples, audioURL: secondAudio)
        XCTAssertEqual(recognized.speakerAliases["them"], "Alex")
        let result = try await service.state(for: second)
        XCTAssertEqual(result.assignments.first?.origin, .profileAutomatic)
        let after = try await service.profiles()
        XCTAssertEqual(after.first?.contributions.count, 1, "An automatic recognition must not reinforce its own profile")
        try await service.prepareDeletion(meeting: first)
        let revoked = try await service.profiles()
        XCTAssertTrue(revoked.isEmpty)
    }

    func testDisablingRememberingStopsMatchingInNewMeetings() async throws {
        let (first, audio, transcript, turns, samples) = try await fixture(visual: true)
        let automatic = await service.process(transcript: transcript, meeting: first, turns: turns, samples: samples, audioURL: audio)
        _ = try await service.choose(.init(label: "them", name: "Alex", remember: true), meeting: first, transcript: automatic)
        let (second, secondAudio, secondTranscript, secondTurns, secondSamples) = try await fixture(visual: false)
        settings.rememberSpeakersOnMac = false
        let result = await service.process(transcript: secondTranscript, meeting: second, turns: secondTurns, samples: secondSamples, audioURL: secondAudio)
        XCTAssertTrue(result.speakerAliases.isEmpty)
        let preserved = try await service.profiles(managing: true)
        XCTAssertEqual(preserved.count, 1)
    }

    func testPrivateEvidenceAndUnappliedCandidatesNeverEnterTranscriptEncoding() async throws {
        let (meeting, audio, transcript, turns, _) = try await fixture(visual: true)
        let result = await service.process(transcript: transcript, meeting: meeting, turns: Array(turns.prefix(1)), samples: [], audioURL: audio)
        XCTAssertTrue(result.speakerAliases.isEmpty)
        let serialized = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for forbidden in ["Alex", "embedding", "participantReference", "profileID", "evidence", "suggestions"] {
            XCTAssertFalse(serialized.contains(forbidden))
        }
        XCTAssertFalse(result.summaryPromptMarkdown.contains("Alex"))
    }

    func testStaleTranscriptShapeCannotReceiveCachedOrdinalAliasesOrAUserCommand() async throws {
        let (meeting, audio, transcript, turns, samples) = try await fixture(visual: true)
        _ = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        var changed = transcript
        changed.segments[0].speaker = "them 2"
        XCTAssertTrue(service.applyingLatestDecision(to: changed, meetingID: meeting.id).speakerAliases.isEmpty)
        do {
            _ = try await service.choose(.init(label: "them", name: "Sam"), meeting: meeting, transcript: changed)
            XCTFail("Accepted a name from a stale transcript")
        } catch { XCTAssertTrue(error is MeetingSpeakerEvidenceStore.Failure) }
    }

    func testRetriedConfirmationIsIdempotentAndCannotCreateTwoProfiles() async throws {
        let (meeting, audio, transcript, turns, samples) = try await fixture(visual: true)
        let automatic = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        let before = try await service.state(for: meeting)
        let choice = MeetingSpeakerIdentityService.Choice(label: "them", name: "Alex", remember: true, expectedRevision: before.revision)
        _ = try await service.choose(choice, meeting: meeting, transcript: automatic)
        let confirmed = try await service.state(for: meeting)
        _ = try await service.choose(choice, meeting: meeting, transcript: automatic)
        let retried = try await service.state(for: meeting)
        let profiles = try await service.profiles()
        XCTAssertEqual(confirmed.revision, retried.revision)
        XCTAssertEqual(retried.decisions.count, 1)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.contributions.count, 1)
    }

    func testUserCanCorrectOneLabelAfterACleanSplitWithoutChangingTheOtherVoice() async throws {
        let (meeting, audio, transcript, turns, _) = try await fixture(visual: true)
        let automatic = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: [], audioURL: audio)
        _ = try await service.choose(.init(label: "them", name: "Alex"), meeting: meeting, transcript: automatic)
        let splitTurns = turns.enumerated().map { index, turn in
            SpeakerAudioTurn(speaker: index < 2 ? "them 1" : "them 2", range: turn.range)
        }
        var splitTranscript = transcript
        for index in splitTranscript.segments.indices { splitTranscript.segments[index].speaker = splitTurns[index].speaker }
        let split = await service.process(transcript: splitTranscript, meeting: meeting, turns: splitTurns, samples: [], audioURL: audio)
        XCTAssertEqual(split.speakerAliases["them 1"], "Alex")
        XCTAssertEqual(split.speakerAliases["them 2"], "Alex")
        _ = try await service.choose(.init(label: "them 2", name: "Sam"), meeting: meeting, transcript: split)
        let retried = await service.process(transcript: splitTranscript, meeting: meeting, turns: splitTurns, samples: [], audioURL: audio)
        XCTAssertEqual(retried.speakerAliases["them 1"], "Alex")
        XCTAssertEqual(retried.speakerAliases["them 2"], "Sam")
    }
}
