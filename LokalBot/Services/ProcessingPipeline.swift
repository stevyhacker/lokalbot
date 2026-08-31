import Foundation

/// Serial post-meeting queue (design doc §6): transcribe each track,
/// merge by timestamp into a speaker-attributed transcript, then summarize
/// with the configured local LLM. Writes transcript.json / transcript.md /
/// summary.md next to the audio.
@MainActor
final class ProcessingPipeline: ObservableObject {

    typealias BuiltInModelPreparer = ThinkExecution.BuiltInModelPreparer

    enum Stage: Equatable {
        case queued
        case waitingForModels
        case preparingTranscriptionModel
        case preparingDiarizationModel
        case preparingSummaryModel
        case transcribing
        case diarizing
        case summarizing
        case failed(String)

        var label: String {
            switch self {
            case .queued: "Queued…"
            case .waitingForModels:
                "Waiting for models — the recording is saved. Download the selected models in Settings → Models, or use Download & process to fetch them now."
            case .preparingTranscriptionModel:
                "Preparing transcription model (download size depends on your selection)…"
            case .preparingDiarizationModel:
                "Preparing speaker diarization model…"
            case .preparingSummaryModel:
                "Preparing summary model (download size depends on your selection)…"
            case .transcribing: "Transcribing…"
            case .diarizing: "Identifying speakers…"
            case .summarizing: "Summarizing…"
            case .failed(let message): "Failed: \(message)"
            }
        }

        /// Compact vocabulary for meeting-list rows. The detail pane keeps
        /// the more descriptive label above; rows need to stay scannable.
        var rowLabel: String {
            switch self {
            case .queued: "Queued"
            case .waitingForModels: "Waiting for models"
            case .preparingTranscriptionModel: "Preparing speech model"
            case .preparingDiarizationModel: "Preparing speaker model"
            case .preparingSummaryModel: "Preparing summary model"
            case .transcribing: "Transcribing"
            case .diarizing: "Identifying speakers"
            case .summarizing: "Summarizing"
            case .failed: "Failed"
            }
        }

        var isFailure: Bool {
            if case .failed = self { true } else { false }
        }

        /// The job is parked because processing would trigger a model download
        /// the user never asked for. Neither a failure nor active work.
        var isWaitingForModels: Bool { self == .waitingForModels }
    }

    /// Who asked for this job. Automatic jobs (auto-transcribe after a
    /// recording, launch crash-resume) must never trigger a model download —
    /// they park as `.waitingForModels` instead. A user-initiated job (Retry,
    /// the Process menu, `--process`) downloads missing models on demand,
    /// because the user just asked for exactly that.
    enum JobOrigin: Equatable {
        case automatic
        case userInitiated
    }

    enum EnqueueOutcome: Equatable {
        case enqueued
        case coalesced
        case updatedActive
        case alreadyProcessing
        case persistenceFailed
    }

    struct Job {
        var meeting: Meeting
        var transcribe: Bool
        var summarize: Bool
        var summaryFollowsSetting: Bool = false
        /// Re-enqueued from the persisted queue after a crash/quit — keep any
        /// per-track checkpoints instead of starting from scratch.
        var resumed: Bool = false
        var origin: JobOrigin = .userInitiated
    }

    struct RetryWork: Equatable {
        var transcribe: Bool
        var summarize: Bool
    }

    /// Resume the exact durable request from its latest completed artifact.
    /// Failed rows retain their explicit/automatic summary provenance, even
    /// after they exhaust the launch-resume attempt budget. Only jobs from an
    /// older build with no durable row fall back to the current setting.
    func retryWork(for meeting: Meeting, autoSummarize: Bool) -> RetryWork {
        let transcriptURL = meeting.folderURL(in: storage)
            .appendingPathComponent("transcript.json")
        return Self.retryWork(
            hasTranscript: FileManager.default.fileExists(atPath: transcriptURL.path),
            autoSummarize: autoSummarize,
            persistedJob: jobStore?.job(meetingID: meeting.id))
    }

    nonisolated static func retryWork(
        hasTranscript: Bool,
        autoSummarize: Bool,
        persistedJob: PipelineJobStore.PendingJob?
    ) -> RetryWork {
        guard let persistedJob else {
            // With no saved intent, never overwrite a completed transcript.
            // The explicit Process menu remains available for a deliberate
            // re-transcription.
            return RetryWork(
                transcribe: !hasTranscript,
                summarize: autoSummarize)
        }
        let resumed = resumedWork(
            pending: Work(
                transcribe: persistedJob.transcribe,
                summarize: persistedJob.summarize),
            summaryFollowsSetting: persistedJob.summaryFollowsSetting,
            autoSummarize: autoSummarize,
            hasTranscript: hasTranscript)
        return RetryWork(
            transcribe: resumed.transcribe,
            summarize: resumed.summarize)
    }

    /// Injectable model-readiness checks so unit tests can exercise the
    /// automation gate without touching real model folders (or the network).
    struct AutomationReadiness {
        var transcription: (AppSettings) -> Bool
        var think: (AppSettings, StorageManager) -> Bool

        static let live = AutomationReadiness(
            transcription: ModelReadinessSnapshot.transcriptionReady,
            think: ModelReadinessSnapshot.thinkReady)
    }

    /// Stage per meeting. `.failed` sticks around until the next attempt;
    /// successful meetings are removed (the files on disk are the result).
    @Published private(set) var stages: [Meeting.ID: Stage] = [:]

    /// Internal so focused feature extensions can share the same storage root
    /// without turning this already-large orchestrator into a monolith.
    let storage: StorageManager
    private let settings: () -> AppSettings
    let thinkExecution: ThinkExecution
    private let automationReadiness: AutomationReadiness
    /// In-memory work list; `jobStore` mirrors it on disk so a crash mid-queue
    /// loses nothing — see `resumePending(meetings:)`.
    private var queue: [Job] = []
    /// Automatic jobs parked because their models are not downloaded yet.
    /// Their durable rows stay pending (no attempt burned), so a relaunch
    /// re-checks them; `retryJobsWaitingForModels()` re-checks mid-session.
    private var waitingForModelsJobs: [Job] = []
    private var isDraining = false
    private var activeMeetingID: Meeting.ID?
    private var activeJob: Job?
    private enum ActivePhase {
        case transcribing
        case summarizing
    }
    private var activePhase: ActivePhase?
    /// Optional lifecycle seam for focused queue tests; production leaves it nil.
    private let transcriptionStarted: ((Meeting.ID) async -> Void)?
    var hasActiveWork: Bool { isDraining || activeMeetingID != nil }
    var hasJobsWaitingForModels: Bool { !waitingForModelsJobs.isEmpty }
    private let diarizer = NeuralDiarizationEngine()
    private let jobStore: PipelineJobStore?
    /// Fired after transcript/summary files land on disk (search re-index).
    var onArtifactsWritten: ((Meeting) -> Void)?

    init(storage: StorageManager, jobStore: PipelineJobStore? = nil,
         settings: @escaping () -> AppSettings,
         thinkExecution: ThinkExecution? = nil,
         builtInModelPreparer: @escaping BuiltInModelPreparer = { entry, storage in
             try await ModelDownloadManager.shared.ensureAvailable(entry, storage: storage)
         },
         automationReadiness: AutomationReadiness = .live,
         transcriptionStarted: ((Meeting.ID) async -> Void)? = nil) {
        self.storage = storage
        self.jobStore = jobStore
        self.settings = settings
        self.thinkExecution = thinkExecution ?? ThinkExecution(
            storage: storage,
            builtInModelPreparer: builtInModelPreparer)
        self.automationReadiness = automationReadiness
        self.transcriptionStarted = transcriptionStarted
    }

    /// One job's requested work, and how a fresh enqueue combines with work
    /// already queued or parked for the same meeting.
    struct Work: Equatable {
        var transcribe: Bool
        var summarize: Bool
    }

    /// Transcription merges by OR — it is the prerequisite for everything
    /// downstream, so a pending one must never be dropped. Summarization does
    /// not: it is the discretionary half, and OR-ing it let a queued job
    /// silently upgrade an explicit "Transcribe" click into "Transcribe &
    /// Summarize". A user-initiated enqueue states the summary intent
    /// outright and the older job defers to it; automatic work still merges,
    /// so a parked summary survives an auto re-enqueue. Pure, so the
    /// escalation rule is testable without a live queue.
    nonisolated static func merged(pending: Work, incoming: Work,
                                   origin: JobOrigin) -> Work {
        Work(
            transcribe: pending.transcribe || incoming.transcribe,
            summarize: origin == .userInitiated
                ? incoming.summarize
                : pending.summarize || incoming.summarize)
    }

    /// Whether merged summary work should be cancelled when auto-summarize is
    /// off at crash-resume time. An explicit summary already waiting remains
    /// explicit; otherwise automatic work follows the current setting.
    nonisolated static func mergedSummaryFollowsSetting(
        pending: Work,
        pendingFollowsSetting: Bool,
        incoming: Work,
        origin: JobOrigin
    ) -> Bool {
        if origin == .userInitiated { return false }
        if pending.summarize, !pendingFollowsSetting { return false }
        return incoming.summarize || pending.summarize
    }

    nonisolated static func resumedWork(
        pending: Work,
        summaryFollowsSetting: Bool,
        autoSummarize: Bool,
        hasTranscript: Bool
    ) -> Work {
        Work(
            transcribe: pending.transcribe && !hasTranscript,
            summarize: pending.summarize
                && (!summaryFollowsSetting || autoSummarize))
    }

    @discardableResult
    func enqueue(_ meeting: Meeting, transcribe: Bool = true, summarize: Bool = true,
                 origin: JobOrigin = .userInitiated) -> EnqueueOutcome {
        // A fresh enqueue supersedes a parked waiting-for-models job: merge its
        // requested work so the new attempt (and its origin) covers both.
        var work = Work(transcribe: transcribe, summarize: summarize)
        var summaryFollowsSetting = origin == .automatic
        if let waitingIndex = waitingForModelsJobs.firstIndex(
            where: { $0.meeting.id == meeting.id }) {
            let waiting = waitingForModelsJobs.remove(at: waitingIndex)
            let pending = Work(
                transcribe: waiting.transcribe,
                summarize: waiting.summarize)
            summaryFollowsSetting = Self.mergedSummaryFollowsSetting(
                pending: pending,
                pendingFollowsSetting: waiting.summaryFollowsSetting,
                incoming: work,
                origin: origin)
            work = Self.merged(pending: pending, incoming: work, origin: origin)
        }
        let transcribe = work.transcribe
        let summarize = work.summarize
        if let index = queue.firstIndex(where: { $0.meeting.id == meeting.id }) {
            let pending = Work(
                transcribe: queue[index].transcribe,
                summarize: queue[index].summarize)
            let mergedFollowsSetting = Self.mergedSummaryFollowsSetting(
                pending: pending,
                pendingFollowsSetting: queue[index].summaryFollowsSetting,
                incoming: work,
                origin: origin)
            let coalesced = Self.merged(
                pending: pending,
                incoming: work,
                origin: origin)
            let mergedTranscribe = coalesced.transcribe
            let mergedSummarize = coalesced.summarize
            if let jobStore,
               !jobStore.enqueue(
                    meetingID: meeting.id,
                    transcribe: mergedTranscribe,
                    summarize: mergedSummarize,
                    summaryFollowsSetting: mergedFollowsSetting) {
                stages[meeting.id] = .failed("Could not persist the processing queue update.")
                return .persistenceFailed
            }
            queue[index].transcribe = mergedTranscribe
            queue[index].summarize = mergedSummarize
            queue[index].summaryFollowsSetting = mergedFollowsSetting
            queue[index].resumed = false
            if origin == .userInitiated { queue[index].origin = .userInitiated }
            lokalbotLog(
                "pipeline coalesced queued meeting=\(meeting.id) "
                    + "transcribe=\(mergedTranscribe) summarize=\(mergedSummarize)")
            return .coalesced
        }
        if activeMeetingID == meeting.id, var activeJob {
            guard activePhase == .transcribing else {
                lokalbotLog(
                    "pipeline request too late while summarizing meeting=\(meeting.id)")
                return .alreadyProcessing
            }
            let pending = Work(
                transcribe: activeJob.transcribe,
                summarize: activeJob.summarize)
            let updated = Self.merged(pending: pending, incoming: work, origin: origin)
            let updatedFollowsSetting = Self.mergedSummaryFollowsSetting(
                pending: pending,
                pendingFollowsSetting: activeJob.summaryFollowsSetting,
                incoming: work,
                origin: origin)
            if let jobStore,
               !jobStore.updateIntent(
                    meetingID: meeting.id,
                    transcribe: updated.transcribe,
                    summarize: updated.summarize,
                    summaryFollowsSetting: updatedFollowsSetting) {
                return .persistenceFailed
            }
            activeJob.transcribe = updated.transcribe
            activeJob.summarize = updated.summarize
            activeJob.summaryFollowsSetting = updatedFollowsSetting
            if origin == .userInitiated { activeJob.origin = .userInitiated }
            self.activeJob = activeJob
            lokalbotLog(
                "pipeline updated active meeting=\(meeting.id) "
                    + "transcribe=\(updated.transcribe) summarize=\(updated.summarize)")
            return .updatedActive
        }
        if let jobStore,
           !jobStore.enqueue(
                meetingID: meeting.id,
                transcribe: transcribe,
                summarize: summarize,
                summaryFollowsSetting: summaryFollowsSetting) {
            stages[meeting.id] = .failed("Could not persist the processing job.")
            return .persistenceFailed
        }
        queue.append(Job(
            meeting: meeting,
            transcribe: transcribe,
            summarize: summarize,
            summaryFollowsSetting: summaryFollowsSetting,
            origin: origin))
        lokalbotLog(
            "pipeline enqueued meeting=\(meeting.id) transcribe=\(transcribe) "
                + "summarize=\(summarize) origin=\(origin == .userInitiated ? "user" : "auto")")
        stages[meeting.id] = .queued
        drain()
        return .enqueued
    }

    /// Re-check every job parked on missing models — call when a model
    /// download finishes or the selection changes. Jobs whose models are still
    /// missing simply park again; nothing downloads from this path.
    func retryJobsWaitingForModels() {
        guard !waitingForModelsJobs.isEmpty else { return }
        let parked = waitingForModelsJobs
        waitingForModelsJobs = []
        for job in parked {
            queue.append(job)
            stages[job.meeting.id] = .queued
        }
        lokalbotLog("pipeline rechecking \(parked.count) job(s) waiting for models")
        drain()
    }

    /// Drop all pipeline state for deleted meetings so a parked or queued job
    /// cannot resurrect processing for a folder that no longer exists.
    func forget(meetingIDs: Set<Meeting.ID>) {
        guard !meetingIDs.isEmpty else { return }
        queue.removeAll { meetingIDs.contains($0.meeting.id) }
        waitingForModelsJobs.removeAll { meetingIDs.contains($0.meeting.id) }
        for id in meetingIDs where stages[id] != nil {
            stages[id] = nil
        }
        if let jobStore {
            for id in meetingIDs { jobStore.markCompleted(meetingID: id) }
        }
    }

    /// Crash recovery, called once at launch: re-enqueue every persisted job
    /// that never reached completion. Jobs whose transcript already made it to
    /// disk skip straight to summarization; jobs that burned through
    /// `PipelineJobStore.maxAutoResumeAttempts` starts stay parked until the
    /// user retries explicitly — a meeting that reliably kills the app must
    /// not crash-loop every launch.
    func resumePending(meetings: [Meeting]) {
        guard let jobStore else { return }
        if !jobStore.prune(existing: Set(meetings.map(\.id))) {
            lokalbotLog("pipeline resume continued after queue prune failure")
        }
        let byID = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
        let autoSummarize = settings().autoSummarize
        for job in jobStore.pendingJobs() {
            guard let meeting = byID[job.meetingID], stages[meeting.id] == nil else { continue }
            let hasTranscript = FileManager.default.fileExists(
                atPath: meeting.folderURL(in: storage)
                    .appendingPathComponent("transcript.json").path)
            lokalbotLog(
                "pipeline resume meeting=\(meeting.id) attempts=\(job.attempts) hasTranscript=\(hasTranscript)")
            let work = Self.resumedWork(
                pending: .init(
                    transcribe: job.transcribe,
                    summarize: job.summarize),
                summaryFollowsSetting: job.summaryFollowsSetting,
                autoSummarize: autoSummarize,
                hasTranscript: hasTranscript)
            queue.append(Job(
                meeting: meeting,
                transcribe: work.transcribe,
                summarize: work.summarize,
                summaryFollowsSetting: job.summaryFollowsSetting,
                resumed: true,
                origin: .automatic))
            stages[meeting.id] = .queued
        }
        for parked in jobStore.parkedJobs() {
            guard byID[parked.meetingID] != nil, stages[parked.meetingID] == nil else { continue }
            stages[parked.meetingID] = .failed(
                parked.lastError ?? "Processing didn't finish after several attempts.")
        }
        drain()
    }

    private func drain() {
        guard !isDraining else { return }
        isDraining = true
        Task {
            while !queue.isEmpty {
                let job = queue.removeFirst()
                activeMeetingID = job.meeting.id
                activeJob = job
                await process(job)
                activePhase = nil
                activeJob = nil
                activeMeetingID = nil
            }
            isDraining = false
        }
    }

    private func process(_ job: Job) async {
        let meeting = job.meeting
        let folder = meeting.folderURL(in: storage)
        guard let config = beginProcessing(job, folder: folder) else { return }
        do {
            let transcriptWrittenThisJob = try await transcribeIfNeeded(
                job,
                folder: folder,
                config: config)
            let resolvedJob = activeJob ?? job
            activePhase = .summarizing
            guard try await summarizeIfNeeded(
                resolvedJob,
                folder: folder,
                config: config,
                transcriptWrittenThisJob: transcriptWrittenThisJob
            ) else { return }
            completeProcessing(resolvedJob)
        } catch {
            // The persisted job row stays — the next launch re-enqueues it
            // (until the attempt cap) so a crash or transient failure never
            // silently drops a meeting. The message is persisted so a job
            // that ends up parked still explains itself after a relaunch.
            jobStore?.markFailed(meetingID: meeting.id, message: error.localizedDescription)
            stages[meeting.id] = .failed(error.localizedDescription)
        }
    }

    private func summarizeIfNeeded(
        _ job: Job,
        folder: URL,
        config: AppSettings,
        transcriptWrittenThisJob: Bool
    ) async throws -> Bool {
        guard job.summarize else { return true }
        guard !parkAutomaticSummaryIfNeeded(
            job,
            config: config,
            transcriptWrittenThisJob: transcriptWrittenThisJob
        ) else { return false }
        if config.summarizerBackend == .builtIn {
            stages[job.meeting.id] = .preparingSummaryModel
            _ = try await thinkExecution.prepareBuiltInModel(config)
        }
        stages[job.meeting.id] = .summarizing
        let transcript = try sanitizedTranscriptForSummary(in: folder)
        try await generateSummaryArtifacts(
            transcript: transcript,
            meeting: job.meeting,
            folder: folder,
            config: config)
        return true
    }

    private func parkAutomaticSummaryIfNeeded(
        _ job: Job,
        config: AppSettings,
        transcriptWrittenThisJob: Bool
    ) -> Bool {
        guard job.origin == .automatic,
              !automationReadiness.think(config, storage) else { return false }
        waitingForModelsJobs.append(Job(
            meeting: job.meeting,
            transcribe: false,
            summarize: true,
            summaryFollowsSetting: job.summaryFollowsSetting,
            resumed: job.resumed,
            origin: .automatic))
        stages[job.meeting.id] = .waitingForModels
        lokalbotLog(
            "pipeline parked summary meeting=\(job.meeting.id) waiting for the Think model")
        if transcriptWrittenThisJob { onArtifactsWritten?(job.meeting) }
        return true
    }

    private func sanitizedTranscriptForSummary(in folder: URL) throws -> Transcript {
        let transcript = try loadTranscript(from: folder)
        let sanitization = TranscriptSanitizer.sanitize(transcript)
        guard sanitization.changed else { return transcript }
        try write(sanitization.transcript, to: folder)
        lokalbotLog(
            "transcript cleanup before summary changedSegments="
                + "\(sanitization.changedSegments) removedWords="
                + "\(sanitization.removedWords) removedCharacters="
                + "\(sanitization.removedCharacters)")
        return sanitization.transcript
    }

    private func generateSummaryArtifacts(
        transcript: Transcript,
        meeting: Meeting,
        folder: URL,
        config: AppSettings
    ) async throws {
        let outcomeContext = try MeetingNotes.promptContext(in: folder)
        let outcomesTask = concurrentOutcomesTask(
            transcript: transcript,
            meeting: meeting,
            folder: folder,
            config: config,
            context: outcomeContext)
        let summary: String
        do {
            summary = try await summarizeWithRetry(
                transcript,
                meeting: meeting,
                config: config)
        } catch {
            await Self.cancelAndWaitForOutcomes(outcomesTask)
            throw error
        }
        try writeSummary(summary, to: folder)
        MeetingSummaryGenerator.removeCheckpoint(in: folder)
        let outcomes = await resolvedOutcomes(
            task: outcomesTask,
            transcript: transcript,
            meeting: meeting,
            folder: folder,
            config: config,
            context: outcomeContext)
        let authoritative = outcomes
            ?? MeetingOutcomes.load(from: folder)
            ?? MeetingOutcomes()
        let synchronized = MeetingSummaryOutcomeSynchronizer.synchronize(
            summary,
            outcomes: authoritative,
            template: config.noteTemplate)
        try writeSummary(synchronized, to: folder)
    }

    private func concurrentOutcomesTask(
        transcript: Transcript,
        meeting: Meeting,
        folder: URL,
        config: AppSettings,
        context: [String]
    ) -> Task<MeetingOutcomes?, Never>? {
        let canUseSinglePass = MeetingOutcomesGenerator.canUseSinglePass(
            transcript: transcript,
            userSpeakerLabel: transcript.displaySpeaker(for: "me"),
            context: context,
            contextTokens: MeetingSummaryGenerator.contextTokenLimit(
                for: config.summarizerBackend),
            outputLanguage: SummaryLanguage.resolvedForTranscript(
                config.summaryLanguage,
                transcript: transcript))
        guard Self.shouldExtractOutcomesConcurrently(
            canUseSinglePass: canUseSinglePass,
            backend: config.summarizerBackend
        ) else { return nil }
        return Task { [weak self] in
            guard let self else { return nil }
            return await self.extractOutcomes(
                transcript: transcript,
                meetingID: meeting.id,
                folder: folder,
                config: config,
                context: context)
        }
    }

    private func summarizeWithRetry(
        _ transcript: Transcript,
        meeting: Meeting,
        config: AppSettings
    ) async throws -> String {
        do {
            return try await summarize(transcript, meeting: meeting, config: config)
        } catch {
            guard let delay = thinkExecution.retryDelay(
                for: error,
                settings: config,
                attempt: 0
            ) else { throw error }
            lokalbotLog(
                "summary retry delay=\(String(format: "%.2f", delay))s "
                    + "after error=\(error.localizedDescription)")
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await summarize(transcript, meeting: meeting, config: config)
        }
    }

    private func resolvedOutcomes(
        task: Task<MeetingOutcomes?, Never>?,
        transcript: Transcript,
        meeting: Meeting,
        folder: URL,
        config: AppSettings,
        context: [String]
    ) async -> MeetingOutcomes? {
        if let task { return await task.value }
        return await extractOutcomes(
            transcript: transcript,
            meetingID: meeting.id,
            folder: folder,
            config: config,
            context: context)
    }

    private func writeSummary(_ summary: String, to folder: URL) throws {
        try summary.data(using: .utf8)?.write(
            to: folder.appendingPathComponent("summary.md"),
            options: .atomic)
    }

    private func beginProcessing(_ job: Job, folder: URL) -> AppSettings? {
        let config = settings()
        guard !parkBeforeStartingIfNeeded(job, folder: folder, config: config) else {
            return nil
        }
        if let jobStore, !jobStore.markStarted(meetingID: job.meeting.id) {
            stages[job.meeting.id] = .failed("Could not durably start this processing job.")
            return nil
        }
        return config
    }

    private func completeProcessing(_ job: Job) {
        if let jobStore, !jobStore.markCompleted(meetingID: job.meeting.id) {
            stages[job.meeting.id] = .failed(
                "Artifacts were saved, but the durable processing queue could not be completed.")
        } else {
            stages[job.meeting.id] = nil
        }
        onArtifactsWritten?(job.meeting)
    }

    private func parkBeforeStartingIfNeeded(
        _ job: Job,
        folder: URL,
        config: AppSettings
    ) -> Bool {
        guard job.origin == .automatic else { return false }
        let requiresTranscription = needsTranscription(job, folder: folder)
        if requiresTranscription, !automationReadiness.transcription(config) {
            park(job, reason: "transcription")
            return true
        }
        guard !requiresTranscription,
              job.summarize,
              !automationReadiness.think(config, storage) else { return false }
        park(
            Job(
                meeting: job.meeting,
                transcribe: false,
                summarize: true,
                summaryFollowsSetting: job.summaryFollowsSetting,
                resumed: job.resumed,
                origin: .automatic),
            reason: "Think")
        return true
    }

    private func needsTranscription(_ job: Job, folder: URL) -> Bool {
        job.transcribe || !FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("transcript.json").path)
    }

    private func park(_ job: Job, reason: String) {
        waitingForModelsJobs.append(job)
        stages[job.meeting.id] = .waitingForModels
        lokalbotLog(
            "pipeline parked meeting=\(job.meeting.id) waiting for the \(reason) model")
    }

    private func transcribeIfNeeded(
        _ job: Job,
        folder: URL,
        config: AppSettings
    ) async throws -> Bool {
        guard needsTranscription(job, folder: folder) else { return false }
        activePhase = .transcribing
        if let transcriptionStarted {
            await transcriptionStarted(job.meeting.id)
        }
        if !job.resumed { clearCheckpoints(in: folder) }
        stages[job.meeting.id] = .preparingTranscriptionModel
        let engine = config.transcriptionEngine()
        stages[job.meeting.id] = .transcribing
        var transcript = try await transcribeTracks(
            folder: folder,
            engine: engine,
            config: config)
        transcript = filterSpeakerBleed(transcript)
        transcript = await diarizeIfNeeded(
            transcript,
            meeting: job.meeting,
            folder: folder,
            config: config)
        transcript = SpeakerAutoNamer.applyingAliases(
            to: transcript,
            participants: job.meeting.resolvedCalendarParticipantIdentities)
        transcript = sanitizeMergedTranscript(transcript)
        try write(transcript, to: folder)
        MeetingAudioFiles.removeRedundantRecoveryFiles(in: folder)
        clearCheckpoints(in: folder)
        return true
    }

    private func filterSpeakerBleed(_ transcript: Transcript) -> Transcript {
        let result = SpeakerBleedFilter.filter(transcript)
        if result.changed {
            lokalbotLog(
                "transcript speaker bleed removedSegments=\(result.removedSegments) "
                    + "removedWords=\(result.removedWords)")
        }
        return result.transcript
    }

    private func diarizeIfNeeded(
        _ transcript: Transcript,
        meeting: Meeting,
        folder: URL,
        config: AppSettings
    ) async -> Transcript {
        guard config.multiSpeakerDiarization,
              MeetingAudioFiles.transcribableURL(for: .system, in: folder) != nil else {
            return transcript
        }
        stages[meeting.id] = .preparingDiarizationModel
        await prepareDiarizationModels()
        stages[meeting.id] = .diarizing
        return await refineSpeakers(
            transcript: transcript,
            folder: folder,
            config: config,
            modelsPrepared: true)
    }

    private func sanitizeMergedTranscript(_ transcript: Transcript) -> Transcript {
        let result = TranscriptSanitizer.sanitize(transcript)
        if result.changed {
            lokalbotLog(
                "transcript cleanup after merge changedSegments="
                    + "\(result.changedSegments) removedWords="
                    + "\(result.removedWords) removedCharacters="
                    + "\(result.removedCharacters)")
        }
        return result.transcript
    }

    // MARK: - Transcription

    /// The microphone track with the remote side subtracted, or nil to
    /// transcribe the recording as it is.
    ///
    /// Returns nil rather than a marginal copy when the filter found little to
    /// cancel. The worker runs outside this type's main-actor isolation, while
    /// cancellation is propagated so a cancelled job never starts ASR anyway.
    private static func echoCancelledMicrophone(in folder: URL, microphone: URL,
                                                config: AppSettings) async throws -> URL? {
        guard config.echoCancellation,
              let reference = MeetingAudioFiles.transcribableURL(for: .system, in: folder)
        else { return nil }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-aec-\(UUID().uuidString).wav")
        do {
            let started = Date()
            let report = try await EchoCancelledTrack.write(microphone: microphone,
                                                            reference: reference,
                                                            to: destination)
            let elapsed = Date().timeIntervalSince(started)
            lokalbotLog(
                "echo cancellation delay=\(String(format: "%.0fms", report.delaySeconds * 1000)) "
                    + "erle=\(String(format: "%.1fdB", report.echoReturnLossDB)) "
                    + "elapsed=\(String(format: "%.1fs", elapsed))")
            guard EchoCancelledTrack.shouldUse(report) else {
                lokalbotLog("echo cancellation discarded reason=insufficient-confidence")
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
            return destination
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        } catch {
            lokalbotLog("echo cancellation failed error=\(error.localizedDescription)")
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }

    private func transcribeTracks(folder: URL,
                                  engine: TranscriptionEngine, config: AppSettings) async throws -> Transcript {
        let language = config.transcriptionLanguage.code
        var tracks: [Transcript] = []
        var trackError: Error?

        for (track, speaker) in [(MeetingAudioFiles.Track.mic, "me"),
                                 (MeetingAudioFiles.Track.system, "them")] {
            let name = track.rawValue
            // Per-track checkpoint: a finished track's transcript survives a
            // crash — and the *other* track failing — so a retry never redoes
            // an hour of completed transcription.
            let checkpoint = Self.checkpointURL(track: name, in: folder)
            if let data = try? Data(contentsOf: checkpoint),
               let cached = try? JSONDecoder().decode(Transcript.self, from: data) {
                lokalbotLog("transcription track restored from checkpoint track=\(name)")
                tracks.append(cached)
                continue
            }
            do {
                guard let url = MeetingAudioFiles.transcribableURL(for: track, in: folder) else {
                    lokalbotLog("transcription track skipped track=\(name) reason=no-readable-audio")
                    continue
                }
                let cancelled = track == .mic
                    ? try await Self.echoCancelledMicrophone(
                        in: folder, microphone: url, config: config)
                    : nil
                defer {
                    if let cancelled { try? FileManager.default.removeItem(at: cancelled) }
                }
                if let transcript = try await transcribeTrack(name: name,
                                                              url: cancelled ?? url,
                                                              speaker: speaker, engine: engine,
                                                              language: language,
                                                              prompt: config.transcriptionPrompt) {
                    if let data = try? JSONEncoder().encode(transcript) {
                        try? data.write(to: checkpoint, options: .atomic)
                    }
                    tracks.append(transcript)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Keep going: the other track may still succeed, and its
                // checkpoint means only this track is redone on retry.
                lokalbotLog("transcription track failed track=\(name) error=\(error.localizedDescription)")
                trackError = trackError ?? error
            }
        }
        if let trackError { throw trackError }
        guard !tracks.isEmpty else {
            throw PipelineError.noAudio
        }
        return Transcript.merged(tracks)
    }

    /// Where a track's finished-but-not-yet-merged transcript is checkpointed.
    /// Deleted once the merged transcript.json lands (or on a fresh enqueue).
    static func checkpointURL(track: String, in folder: URL) -> URL {
        folder.appendingPathComponent("transcript.\(track).partial.json")
    }

    private func clearCheckpoints(in folder: URL) {
        for name in ["mic", "system"] {
            try? FileManager.default.removeItem(at: Self.checkpointURL(track: name, in: folder))
        }
        MeetingSummaryGenerator.removeCheckpoint(in: folder)
    }

    private func transcribeTrack(name: String, url: URL, speaker: String,
                                 engine: TranscriptionEngine,
                                 language: String?,
                                 prompt: String?) async throws -> Transcript? {
        guard let duration = AudioFileInspector.duration(at: url),
              duration >= AudioFileInspector.minimumTranscribableDuration else {
            lokalbotLog("transcription track skipped track=\(name) reason=no-audio")
            return nil
        }
        // Skip a track with no detected speech (e.g. your mic while muted the
        // whole call) — feeding silence to the ASR model can hallucinate words.
        // Conservative: only skip on a confident "nothing here"; VAD errors
        // return nil and we transcribe anyway, never dropping real audio.
        if let speech = await SpeechActivity.shared.speechSeconds(in: url), speech < 0.5 {
            lokalbotLog("transcription track skipped track=\(name) reason=no-speech")
            return nil
        }

        let started = Date()
        lokalbotLog(
            "transcription track start track=\(name) engine=\(engine.displayName) duration=\(Self.formatSeconds(duration)) language=\(language ?? "auto")")
        var transcript = try await engine.transcribe(
            audio: url,
            language: language,
            prompt: prompt)
        for i in transcript.segments.indices { transcript.segments[i].speaker = speaker }
        let sanitization = TranscriptSanitizer.sanitize(transcript)
        transcript = sanitization.transcript
        if sanitization.changed {
            lokalbotLog(
                "transcript cleanup track=\(name) changedSegments="
                    + "\(sanitization.changedSegments) removedWords="
                    + "\(sanitization.removedWords) removedCharacters="
                    + "\(sanitization.removedCharacters)")
        }

        let elapsed = Date().timeIntervalSince(started)
        let rtfx = elapsed > 0 ? duration / elapsed : 0
        lokalbotLog(
            "transcription track done track=\(name) engine=\(engine.displayName) duration=\(Self.formatSeconds(duration)) elapsed=\(Self.formatSeconds(elapsed)) rtfx=\(Self.formatMultiplier(rtfx)) segments=\(transcript.segments.count)")
        return transcript
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.2fs", seconds)
    }

    private static func formatMultiplier(_ value: Double) -> String {
        String(format: "%.2fx", value)
    }

    /// Optionally split the catch-all "them" speaker into "Them 1" / "Them 2"
    /// using FluidAudio's offline diarizer. No-op (returns the input
    /// unchanged) unless the user opted in AND a system track exists. Never
    /// crashes the pipeline — a diarization failure just leaves the
    /// pre-existing labels alone.
    private func refineSpeakers(transcript: Transcript,
                                folder: URL,
                                config: AppSettings,
                                modelsPrepared: Bool = false) async -> Transcript {
        guard config.multiSpeakerDiarization else { return transcript }
        guard let systemURL = MeetingAudioFiles.transcribableURL(for: .system, in: folder) else {
            return transcript
        }
        if !modelsPrepared { await prepareDiarizationModels() }
        let segments = await diarizer.diarize(url: systemURL)
        guard !segments.isEmpty else { return transcript }

        // Stable speaker-id → "Them N" mapping in first-appearance order.
        var order: [String] = []
        for segment in segments where !order.contains(segment.speakerId) {
            order.append(segment.speakerId)
        }
        // Don't add the "1" suffix when only one remote speaker was detected
        // — that's the existing single-Them case, no point churning the label.
        let useNumbers = order.count > 1
        let mapping = Dictionary(uniqueKeysWithValues: order.enumerated().map { idx, id in
            (id, useNumbers ? "them \(idx + 1)" : "them")
        })

        var labelled = transcript
        for index in labelled.segments.indices where labelled.segments[index].speaker == "them" {
            let segment = labelled.segments[index]
            if let speakerId = segments.dominantSpeaker(coveringStart: segment.start, end: segment.end),
               let label = mapping[speakerId] {
                labelled.segments[index].speaker = label
            }
        }
        return labelled
    }

    /// Shared by recording-time prewarm and the post-meeting stage. The
    /// `NeuralDiarizationEngine` instance is retained by this pipeline, so the
    /// downloaded/prepared models are reused instead of rebuilt per job.
    func prepareDiarizationModels() async {
        await diarizer.prepareModels()
        // A recording-time prewarm may already own the engine's preparation.
        // `prepareModels()` is idempotent and returns for secondary callers, so
        // wait for that retained instance to finish before entering diarization.
        while diarizer.isPreparing, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func write(_ transcript: Transcript, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(
            to: folder.appendingPathComponent("transcript.json"), options: .atomic)
        try transcript.markdown.data(using: .utf8)?.write(
            to: folder.appendingPathComponent("transcript.md"), options: .atomic)
    }

    func loadTranscript(from folder: URL) throws -> Transcript {
        let url = folder.appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url) else { throw PipelineError.noTranscript }
        return try JSONDecoder().decode(Transcript.self, from: data)
    }

    func saveTranscript(_ transcript: Transcript, for meeting: Meeting) throws {
        try write(transcript, to: meeting.folderURL(in: storage))
    }

    // MARK: - Summarization

    nonisolated static func shouldExtractOutcomesConcurrently(
        canUseSinglePass: Bool,
        backend: AppSettings.SummarizerBackend
    ) -> Bool {
        backend == .builtIn
            && canUseSinglePass
    }

    private func summarize(_ transcript: Transcript, meeting: Meeting,
                           config: AppSettings) async throws -> String {
        let started = Date()
        let engine = try await thinkExecution.makeTextEngine(config)
        let wordCount = transcript.languageDetectionText
            .split(whereSeparator: { $0.isWhitespace }).count
        // Resolve `.matchTranscript` against raw spoken text now so both the
        // chunk extractions and the final synthesis share the same language
        // directive. Do not use rendered Markdown here: timestamps and speaker
        // labels can skew NaturalLanguage on short transcripts.
        let language = SummaryLanguage.resolvedForTranscript(config.summaryLanguage,
                                                             transcript: transcript)
        let userSpeakerLabel = transcript.displaySpeaker(for: "me")
        let systemPrompt = PromptTemplates.systemPrompt(for: config.noteTemplate,
                                                        summaryLanguage: language,
                                                        userSpeakerLabel: userSpeakerLabel)
        // Quick notes the user typed during the meeting ride along as context
        // in the final pass (both paths) — they're the user's own words, so
        // the summary should fold them in rather than rediscover them.
        let noteContext = try MeetingNotes.promptContext(in: meeting.folderURL(in: storage))
        let body = try await MeetingSummaryGenerator.generate(
            transcript: transcript,
            engine: engine,
            systemPrompt: systemPrompt,
            template: config.noteTemplate,
            language: language,
            userSpeakerLabel: userSpeakerLabel,
            context: noteContext,
            contextTokens: MeetingSummaryGenerator.contextTokenLimit(
                for: config.summarizerBackend),
            checkpointURL: MeetingSummaryGenerator.checkpointURL(
                in: meeting.folderURL(in: storage)))

        let date = meeting.startedAt.formatted(date: .long, time: .shortened)
        var header = "# \(meeting.title) — \(date)\n"
        header += "**Duration:** \(meeting.durationLabel) · **App:** \(meeting.appName)"
        header += " · **Words:** \(WordCountFormatter.format(words: wordCount))"
        header += " · **Template:** \(config.noteTemplate.displayName)"
        if let promptLanguage = language.promptLanguageName {
            header += " · **Language:** \(promptLanguage)"
        }
        header += " · **Model:** \(engine.displayName)\n\n"
        GenerationMetricsStore.shared.record(
            label: "Summary · \(engine.displayName)",
            durationSec: Date().timeIntervalSince(started),
            approxTokens: TokenCountEstimator.estimate(body))
        return header + body + "\n"
    }

    /// Outcomes scan the complete transcript through bounded, cited chunks.
    /// Failure is non-fatal and never overwrites the last successful artifact.
    private func extractOutcomes(
        transcript: Transcript,
        meetingID: Meeting.ID,
        folder: URL,
        config: AppSettings,
        context: [String]
    ) async -> MeetingOutcomes? {
        do {
            try Task.checkCancellation()
            let engine = try await thinkExecution.makeTextEngine(config)
            let userSpeakerLabel = transcript.displaySpeaker(for: "me")
            let outputLanguage = SummaryLanguage.resolvedForTranscript(
                config.summaryLanguage,
                transcript: transcript)
            let outcomes = try await MeetingOutcomesGenerator.generate(
                transcript: transcript,
                engine: engine,
                userSpeakerLabel: userSpeakerLabel,
                context: context,
                contextTokens: MeetingSummaryGenerator.contextTokenLimit(
                    for: config.summarizerBackend),
                meetingID: meetingID,
                checkpointURL: MeetingOutcomesGenerator.checkpointURL(in: folder),
                outputLanguage: outputLanguage)
            try Task.checkCancellation()
            let previous = MeetingOutcomes.load(from: folder)
            let previousState = MeetingOutcomeStore.loadState(from: folder)
            try outcomes.write(to: folder)
            if let previous {
                let reconciled = MeetingOutcomeStore.reconcileState(
                    previousState, from: previous, to: outcomes)
                try MeetingOutcomeStore.writeState(reconciled, to: folder)
            }
            MeetingOutcomesGenerator.removeCheckpoint(in: folder)
            return outcomes
        } catch {
            lokalbotLog("outcomes extraction failed error=\(error.localizedDescription)")
            return nil
        }
    }

    /// Cancellation is cooperative; some inference backends may not return
    /// immediately. A failed summary must not let its sibling outcomes task
    /// outlive the job and race a retry's artifact writes.
    nonisolated static func cancelAndWaitForOutcomes<Success: Sendable>(
        _ task: Task<Success, Never>?
    ) async {
        guard let task else { return }
        task.cancel()
        _ = await task.value
    }

    enum PipelineError: LocalizedError {
        case noAudio, noTranscript
        var errorDescription: String? {
            switch self {
            case .noAudio: "No audio tracks found in the meeting folder."
            case .noTranscript: "No transcript yet — transcribe the meeting first."
            }
        }
    }
}
