import XCTest
@testable import LokalBot

/// The automation gate: automatic jobs (auto-transcribe after a recording,
/// launch resume) must never trigger a model download — they park as
/// `.waitingForModels` without burning auto-resume attempts. User-initiated
/// jobs pass straight through.
@MainActor
final class ProcessingPipelineAutomationGateTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeMeeting() -> Meeting {
        Meeting(id: UUID(), title: "Standup", appName: "Zoom",
                startedAt: Date(), endedAt: Date(),
                relativePath: "meetings/2026/08/17-standup-\(UUID().uuidString.prefix(8))")
    }

    /// Readiness stub whose answers can flip mid-test, standing in for a
    /// model download completing.
    private final class ReadinessBox {
        var transcriptionReady = false
        var thinkReady = false
    }

    private func makePipeline(root: URL,
                              jobStore: PipelineJobStore? = nil,
                              readiness: ReadinessBox) -> ProcessingPipeline {
        ProcessingPipeline(
            storage: StorageManager(rootURL: root),
            jobStore: jobStore,
            settings: { AppSettings() },
            automationReadiness: .init(
                transcription: { _ in readiness.transcriptionReady },
                think: { _, _ in readiness.thinkReady }))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testStageVocabularyForWaitingForModels() {
        let stage = ProcessingPipeline.Stage.waitingForModels
        XCTAssertEqual(stage.rowLabel, "Waiting for models")
        XCTAssertFalse(stage.isFailure)
        XCTAssertTrue(stage.isWaitingForModels)
        XCTAssertFalse(ProcessingPipeline.Stage.queued.isWaitingForModels)
    }

    func testAutomaticJobParksWithoutBurningAttemptsWhenModelMissing() async throws {
        let root = try makeRoot()
        let jobStore = PipelineJobStore(
            databaseURL: root.appendingPathComponent("test.sqlite"))
        let readiness = ReadinessBox()
        let pipeline = makePipeline(root: root, jobStore: jobStore, readiness: readiness)
        let meeting = makeMeeting()

        pipeline.enqueue(meeting, transcribe: true, summarize: true, origin: .automatic)
        await waitUntil { pipeline.stages[meeting.id] == .waitingForModels }

        XCTAssertEqual(pipeline.stages[meeting.id], .waitingForModels)
        XCTAssertTrue(pipeline.hasJobsWaitingForModels)
        XCTAssertFalse(pipeline.hasActiveWork)
        let pending = jobStore.pendingJobs()
        XCTAssertEqual(pending.count, 1, "the durable row must survive parking")
        XCTAssertEqual(pending.first?.attempts, 0,
                       "waiting must not burn launch auto-resume attempts")
    }

    func testParkedJobProcessesOnceModelsArrive() async throws {
        let root = try makeRoot()
        let readiness = ReadinessBox()
        let pipeline = makePipeline(root: root, readiness: readiness)
        let meeting = makeMeeting()

        pipeline.enqueue(meeting, transcribe: true, summarize: false, origin: .automatic)
        await waitUntil { pipeline.stages[meeting.id] == .waitingForModels }
        XCTAssertEqual(pipeline.stages[meeting.id], .waitingForModels)

        // Still missing: a re-check parks again instead of downloading.
        pipeline.retryJobsWaitingForModels()
        await waitUntil { pipeline.stages[meeting.id] == .waitingForModels }
        XCTAssertEqual(pipeline.stages[meeting.id], .waitingForModels)

        // "Download finished": the job passes the gate and actually runs —
        // this hermetic meeting has no audio, so passing the gate shows up
        // as the pipeline's no-audio failure rather than a parked stage.
        readiness.transcriptionReady = true
        pipeline.retryJobsWaitingForModels()
        await waitUntil { pipeline.stages[meeting.id]?.isFailure == true }
        XCTAssertEqual(pipeline.stages[meeting.id]?.isFailure, true)
        XCTAssertFalse(pipeline.hasJobsWaitingForModels)
    }

    func testUserInitiatedJobBypassesTheGate() async throws {
        let root = try makeRoot()
        let readiness = ReadinessBox()
        let pipeline = makePipeline(root: root, readiness: readiness)
        let meeting = makeMeeting()

        // Default origin is user-initiated (Retry, Process menu, --process):
        // the job runs — and fails on missing audio — instead of parking.
        pipeline.enqueue(meeting, transcribe: true, summarize: false)
        await waitUntil { pipeline.stages[meeting.id]?.isFailure == true }
        XCTAssertEqual(pipeline.stages[meeting.id]?.isFailure, true)
        XCTAssertFalse(pipeline.hasJobsWaitingForModels)
    }

    func testExplicitRetryAbsorbsTheParkedJob() async throws {
        let root = try makeRoot()
        let readiness = ReadinessBox()
        let pipeline = makePipeline(root: root, readiness: readiness)
        let meeting = makeMeeting()

        pipeline.enqueue(meeting, transcribe: true, summarize: true, origin: .automatic)
        await waitUntil { pipeline.stages[meeting.id] == .waitingForModels }

        // "Download & process" re-enqueues user-initiated: the parked copy is
        // merged away and the job runs.
        pipeline.enqueue(meeting, transcribe: true, summarize: true)
        await waitUntil { pipeline.stages[meeting.id]?.isFailure == true }
        XCTAssertEqual(pipeline.stages[meeting.id]?.isFailure, true)
        XCTAssertFalse(pipeline.hasJobsWaitingForModels,
                       "the parked copy must not linger after an explicit retry")
    }

    func testAutomaticSummaryParksButKeepsExistingTranscript() async throws {
        let root = try makeRoot()
        let jobStore = PipelineJobStore(
            databaseURL: root.appendingPathComponent("test.sqlite"))
        let readiness = ReadinessBox()
        readiness.transcriptionReady = true
        let pipeline = makePipeline(root: root, jobStore: jobStore, readiness: readiness)
        let meeting = makeMeeting()

        // A transcript already on disk (live transcription, earlier run):
        // only the summary needs Think, so only the summary waits.
        let storage = StorageManager(rootURL: root)
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("transcript.json"))

        pipeline.enqueue(meeting, transcribe: false, summarize: true, origin: .automatic)
        await waitUntil { pipeline.stages[meeting.id] == .waitingForModels }

        XCTAssertEqual(pipeline.stages[meeting.id], .waitingForModels)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("transcript.json").path),
            "parking the summary must not disturb the transcript")

        // Repeated launch/download readiness checks while Think is still
        // absent must remain pure waits, not crash-loop processing attempts.
        for _ in 0..<(PipelineJobStore.maxAutoResumeAttempts + 1) {
            pipeline.retryJobsWaitingForModels()
            await waitUntil {
                pipeline.stages[meeting.id] == .waitingForModels
                    && !pipeline.hasActiveWork
            }
        }
        let pending = jobStore.pendingJobs()
        XCTAssertEqual(pending.first?.attempts, 0,
                       "summary-only waiting must preserve the auto-resume budget")
        XCTAssertTrue(jobStore.parkedJobs().isEmpty)
    }

    // MARK: - Readiness helpers

    func testThinkReadinessTracksBackendAndLocalModel() throws {
        let root = try makeRoot()
        let storage = StorageManager(rootURL: root)
        var settings = AppSettings()
        settings.summarizerBackend = .builtIn

        XCTAssertFalse(ModelReadinessSnapshot.thinkReady(settings, storage: storage),
                       "no GGUF on disk yet")

        let entry = try XCTUnwrap(ModelCatalog.entry(id: settings.builtInModelID))
        let url = storage.rootURL.appendingPathComponent("models/\(entry.fileName)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("GGUF".utf8).write(to: url)
        XCTAssertTrue(ModelReadinessSnapshot.thinkReady(settings, storage: storage))

        settings.summarizerBackend = .openAICompatible
        XCTAssertTrue(ModelReadinessSnapshot.thinkReady(settings, storage: storage),
                      "remote backends have their own approval flow — never gated here")
    }

    func testMissingCoreModelBytesCountsOnlyMissingGGUFs() throws {
        let root = try makeRoot()
        let storage = StorageManager(rootURL: root)
        var settings = AppSettings()
        settings.summarizerBackend = .builtIn
        let think = ModelCatalog.Entry(
            id: "custom-think", displayName: "Think", fileName: "think.gguf",
            url: "https://example.com/think.gguf", sizeBytes: 1_000, sizeGB: 0.001,
            blurb: "", disablesThinking: false)
        let autocomplete = ModelCatalog.Entry(
            id: "custom-ac", displayName: "Autocomplete", fileName: "ac.gguf",
            url: "https://example.com/ac.gguf", sizeBytes: 500, sizeGB: 0.0005,
            blurb: "", disablesThinking: false)
        settings.customBuiltInModels = [think, autocomplete]
        settings.builtInModelID = think.id
        settings.cotypingBuiltInModelID = autocomplete.id

        XCTAssertEqual(
            ModelReadinessSnapshot.missingCoreModelBytes(settings, storage: storage), 1_500)

        let url = storage.rootURL.appendingPathComponent("models/\(autocomplete.fileName)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("GGUF".utf8).write(to: url)
        XCTAssertEqual(
            ModelReadinessSnapshot.missingCoreModelBytes(settings, storage: storage), 1_000,
            "a model already on disk no longer counts as pending download")

        settings.summarizerBackend = .ollama
        XCTAssertEqual(
            ModelReadinessSnapshot.missingCoreModelBytes(settings, storage: storage), 0,
            "a remote Think backend needs no local Think download")
    }

    func testProcessingReadinessChangeTracksPipelineModelSelections() {
        let original = AppSettings()

        var changed = original
        changed.transcriptionModel = .parakeetV3
        XCTAssertTrue(ModelReadinessSnapshot.processingReadinessChanged(
            from: original, to: changed))

        changed = original
        changed.summarizerBackend = .ollama
        XCTAssertTrue(ModelReadinessSnapshot.processingReadinessChanged(
            from: original, to: changed))

        changed = original
        changed.builtInModelID = "another-think-model"
        XCTAssertTrue(ModelReadinessSnapshot.processingReadinessChanged(
            from: original, to: changed))

        changed = original
        changed.autoSummarize.toggle()
        XCTAssertFalse(ModelReadinessSnapshot.processingReadinessChanged(
            from: original, to: changed),
            "non-readiness settings must not churn parked jobs")
    }

    func testOnboardingDownloadStateStopsSpinningAndAllowsRetryAfterFailure() {
        XCTAssertEqual(
            OnboardingModelDownloadState.resolve(
                coreReady: false, activeDownloads: 0,
                isPreparingTranscription: false, error: "Network unavailable"),
            .download(error: "Network unavailable"))
        XCTAssertEqual(
            OnboardingModelDownloadState.resolve(
                coreReady: false, activeDownloads: 0,
                isPreparingTranscription: true, error: nil),
            .downloading)
        XCTAssertEqual(
            OnboardingModelDownloadState.resolve(
                coreReady: true, activeDownloads: 0,
                isPreparingTranscription: false, error: nil),
            .ready)
    }

    func testForgetDropsParkedJobsForDeletedMeetings() async throws {
        let root = try makeRoot()
        let jobStore = PipelineJobStore(
            databaseURL: root.appendingPathComponent("test.sqlite"))
        let readiness = ReadinessBox()
        let pipeline = makePipeline(root: root, jobStore: jobStore, readiness: readiness)
        let meeting = makeMeeting()

        pipeline.enqueue(meeting, transcribe: true, summarize: true, origin: .automatic)
        await waitUntil { pipeline.stages[meeting.id] == .waitingForModels }

        pipeline.forget(meetingIDs: [meeting.id])

        XCTAssertNil(pipeline.stages[meeting.id])
        XCTAssertFalse(pipeline.hasJobsWaitingForModels)
        XCTAssertTrue(jobStore.pendingJobs().isEmpty,
                      "a deleted meeting's durable row must not resurrect processing")
    }
}
