import Foundation

/// Serial post-meeting queue (design doc §6): transcribe each track,
/// merge by timestamp into a speaker-attributed transcript, then summarize
/// with the configured local LLM. Writes transcript.json / transcript.md /
/// summary.md next to the audio.
@MainActor
final class ProcessingPipeline: ObservableObject {

    typealias BuiltInModelPreparer = (ModelCatalog.Entry, StorageManager) async throws -> URL

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
    enum JobOrigin {
        case automatic
        case userInitiated
    }

    struct Job {
        var meeting: Meeting
        var transcribe: Bool
        var summarize: Bool
        /// Re-enqueued from the persisted queue after a crash/quit — keep any
        /// per-track checkpoints instead of starting from scratch.
        var resumed: Bool = false
        var origin: JobOrigin = .userInitiated
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

    private let storage: StorageManager
    private let settings: () -> AppSettings
    private let builtInModelPreparer: BuiltInModelPreparer
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
    var hasActiveWork: Bool { isDraining || activeMeetingID != nil }
    var hasJobsWaitingForModels: Bool { !waitingForModelsJobs.isEmpty }
    private let diarizer = NeuralDiarizationEngine()
    private let jobStore: PipelineJobStore?
    /// Fired after transcript/summary files land on disk (search re-index).
    var onArtifactsWritten: ((Meeting) -> Void)?

    init(storage: StorageManager, jobStore: PipelineJobStore? = nil,
         settings: @escaping () -> AppSettings,
         builtInModelPreparer: @escaping BuiltInModelPreparer = { entry, storage in
             try await ModelDownloadManager.shared.ensureAvailable(entry, storage: storage)
         },
         automationReadiness: AutomationReadiness = .live) {
        self.storage = storage
        self.jobStore = jobStore
        self.settings = settings
        self.builtInModelPreparer = builtInModelPreparer
        self.automationReadiness = automationReadiness
    }

    func enqueue(_ meeting: Meeting, transcribe: Bool = true, summarize: Bool = true,
                 origin: JobOrigin = .userInitiated) {
        // A fresh enqueue supersedes a parked waiting-for-models job: merge its
        // requested work so the new attempt (and its origin) covers both.
        var transcribe = transcribe
        var summarize = summarize
        if let waitingIndex = waitingForModelsJobs.firstIndex(
            where: { $0.meeting.id == meeting.id }) {
            let waiting = waitingForModelsJobs.remove(at: waitingIndex)
            transcribe = transcribe || waiting.transcribe
            summarize = summarize || waiting.summarize
        }
        if let index = queue.firstIndex(where: { $0.meeting.id == meeting.id }) {
            let mergedTranscribe = queue[index].transcribe || transcribe
            let mergedSummarize = queue[index].summarize || summarize
            if let jobStore,
               !jobStore.enqueue(
                    meetingID: meeting.id,
                    transcribe: mergedTranscribe,
                    summarize: mergedSummarize) {
                stages[meeting.id] = .failed("Could not persist the processing queue update.")
                return
            }
            queue[index].transcribe = mergedTranscribe
            queue[index].summarize = mergedSummarize
            queue[index].resumed = false
            if origin == .userInitiated { queue[index].origin = .userInitiated }
            lokalbotLog("pipeline coalesced queued meeting=\(meeting.id)")
            return
        }
        guard activeMeetingID != meeting.id else {
            lokalbotLog("pipeline duplicate ignored while active meeting=\(meeting.id)")
            return
        }
        if let jobStore,
           !jobStore.enqueue(
                meetingID: meeting.id, transcribe: transcribe, summarize: summarize) {
            stages[meeting.id] = .failed("Could not persist the processing job.")
            return
        }
        queue.append(Job(meeting: meeting, transcribe: transcribe, summarize: summarize,
                         origin: origin))
        stages[meeting.id] = .queued
        drain()
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
        for job in jobStore.pendingJobs() {
            guard let meeting = byID[job.meetingID], stages[meeting.id] == nil else { continue }
            let hasTranscript = FileManager.default.fileExists(
                atPath: meeting.folderURL(in: storage)
                    .appendingPathComponent("transcript.json").path)
            lokalbotLog(
                "pipeline resume meeting=\(meeting.id) attempts=\(job.attempts) hasTranscript=\(hasTranscript)")
            queue.append(Job(meeting: meeting,
                             transcribe: job.transcribe && !hasTranscript,
                             summarize: job.summarize,
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
                await process(job)
                activeMeetingID = nil
            }
            isDraining = false
        }
    }

    private func process(_ job: Job) async {
        let meeting = job.meeting
        let folder = meeting.folderURL(in: storage)
        let config = settings()
        // Automatic work never ambush-downloads a model: park the job instead
        // (before markStarted, so waiting burns no auto-resume attempts and
        // the durable row is re-checked on the next launch). A user-initiated
        // job passes through and downloads on demand.
        if job.origin == .automatic {
            let needsTranscription = job.transcribe || !FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("transcript.json").path)
            if needsTranscription, !automationReadiness.transcription(config) {
                waitingForModelsJobs.append(job)
                stages[meeting.id] = .waitingForModels
                lokalbotLog(
                    "pipeline parked meeting=\(meeting.id) waiting for the transcription model")
                return
            }
        }
        if let jobStore, !jobStore.markStarted(meetingID: meeting.id) {
            stages[meeting.id] = .failed("Could not durably start this processing job.")
            return
        }
        var transcriptWrittenThisJob = false
        do {
            if job.transcribe || !FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("transcript.json").path) {
                // A fresh enqueue means "transcribe with today's settings" —
                // stale checkpoints from an earlier failed attempt may have
                // been produced by a different model. Only a crash resume
                // trusts them.
                if !job.resumed { clearCheckpoints(in: folder) }
                stages[meeting.id] = .preparingTranscriptionModel
                let engine = config.transcriptionEngine()   // engines prepare lazily inside transcribe

                stages[meeting.id] = .transcribing
                var transcript = try await transcribeTracks(meeting: meeting, folder: folder,
                                                            engine: engine, config: config)
                if config.multiSpeakerDiarization,
                   MeetingAudioFiles.transcribableURL(for: .system, in: folder) != nil {
                    stages[meeting.id] = .preparingDiarizationModel
                    await prepareDiarizationModels()
                    stages[meeting.id] = .diarizing
                    transcript = await refineSpeakers(
                        transcript: transcript,
                        meeting: meeting,
                        folder: folder,
                        config: config,
                        modelsPrepared: true)
                }
                transcript = SpeakerAutoNamer.applyingAliases(
                    to: transcript, participantNames: meeting.participantNameHints ?? [])
                try write(transcript, to: folder)
                // A finalized AAC track makes its CAF duplicate redundant. A
                // crash-recovery CAF remains when the AAC container is broken,
                // preserving playable audio after the transcript is written.
                MeetingAudioFiles.removeRedundantRecoveryFiles(in: folder)
                clearCheckpoints(in: folder)
                transcriptWrittenThisJob = true
            }
            if job.summarize {
                // Missing Think model on automatic work: keep the transcript
                // that just landed and park only the summary. The durable row
                // stays pending, so the summary still happens once the model
                // is downloaded (or the user asks explicitly).
                if job.origin == .automatic, !automationReadiness.think(config, storage) {
                    waitingForModelsJobs.append(Job(
                        meeting: meeting, transcribe: false, summarize: true,
                        resumed: job.resumed, origin: .automatic))
                    stages[meeting.id] = .waitingForModels
                    lokalbotLog(
                        "pipeline parked summary meeting=\(meeting.id) waiting for the Think model")
                    if transcriptWrittenThisJob { onArtifactsWritten?(meeting) }
                    return
                }
                if config.summarizerBackend == .builtIn {
                    stages[meeting.id] = .preparingSummaryModel
                    _ = try await prepareBuiltInModel(config)
                }
                stages[meeting.id] = .summarizing
                let transcript = try loadTranscript(from: folder)
                // The default built-in server supports continuous batching.
                // For a short transcript, outcomes and summary are independent
                // reads of the same source, so overlap their generation instead
                // of paying two serial full-prefill passes. Long transcripts
                // still wait because outcomes intentionally consume the summary.
                let concurrentOutcomes = Self.shouldExtractOutcomesConcurrently(
                    transcriptCharacterCount: transcript.markdown.count,
                    backend: config.summarizerBackend)
                let outcomesTask: Task<Void, Never>? = concurrentOutcomes
                    ? Task { [weak self] in
                        await self?.extractOutcomes(
                            transcript: transcript, summary: "", meetingID: meeting.id,
                            folder: folder, config: config)
                    }
                    : nil
                let summary: String
                do {
                    do {
                        summary = try await summarize(transcript, meeting: meeting, config: config)
                    } catch {
                        guard let delay = TextEngineRetryPolicy.delay(
                            for: error, attempt: 0) else { throw error }
                        // One bounded retry for transient network, rate-limit,
                        // or server failures. Deterministic 4xx/schema/payload
                        // failures surface immediately instead of doubling work.
                        lokalbotLog(
                            "summary retry delay=\(String(format: "%.2f", delay))s "
                                + "after error=\(error.localizedDescription)")
                        try await Task.sleep(
                            nanoseconds: UInt64(delay * 1_000_000_000))
                        summary = try await summarize(transcript, meeting: meeting, config: config)
                    }
                } catch {
                    await Self.cancelAndWaitForOutcomes(outcomesTask)
                    throw error
                }
                try summary.data(using: .utf8)?.write(
                    to: folder.appendingPathComponent("summary.md"), options: .atomic)
                if let outcomesTask {
                    await outcomesTask.value
                } else {
                    await extractOutcomes(transcript: transcript, summary: summary,
                                          meetingID: meeting.id, folder: folder, config: config)
                }
            }
            if let jobStore, !jobStore.markCompleted(meetingID: meeting.id) {
                stages[meeting.id] = .failed(
                    "Artifacts were saved, but the durable processing queue could not be completed.")
                onArtifactsWritten?(meeting)
                return
            }
            stages[meeting.id] = nil
            onArtifactsWritten?(meeting)
        } catch {
            // The persisted job row stays — the next launch re-enqueues it
            // (until the attempt cap) so a crash or transient failure never
            // silently drops a meeting. The message is persisted so a job
            // that ends up parked still explains itself after a relaunch.
            jobStore?.markFailed(meetingID: meeting.id, message: error.localizedDescription)
            stages[meeting.id] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Transcription

    private func transcribeTracks(meeting: Meeting, folder: URL,
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
                if let transcript = try await transcribeTrack(name: name, url: url,
                                                              speaker: speaker, engine: engine,
                                                              language: language) {
                    if let data = try? JSONEncoder().encode(transcript) {
                        try? data.write(to: checkpoint, options: .atomic)
                    }
                    tracks.append(transcript)
                }
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
    }

    private func transcribeTrack(name: String, url: URL, speaker: String,
                                 engine: TranscriptionEngine,
                                 language: String?) async throws -> Transcript? {
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
        var transcript = try await engine.transcribe(audio: url, language: language)
        for i in transcript.segments.indices { transcript.segments[i].speaker = speaker }

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
                                meeting: Meeting,
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
        transcriptCharacterCount: Int,
        backend: AppSettings.SummarizerBackend
    ) -> Bool {
        backend == .builtIn
            && transcriptCharacterCount <= OutcomesExtractor.transcriptCharacterLimit
    }

    private func summarize(_ transcript: Transcript, meeting: Meeting,
                           config: AppSettings) async throws -> String {
        let started = Date()
        let engine = try await makeTextEngine(config)
        let text = transcript.markdown
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
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
        let noteContext = MeetingNotes.promptContext(in: meeting.folderURL(in: storage))
        let body: String

        // Map-reduce long meetings: per-chunk notes, then one synthesis pass.
        if text.count > 24_000 {
            var notes: [String] = []
            let chunkSystem = PromptTemplates.chunkExtractionSystem(
                summaryLanguage: language,
                userSpeakerLabel: userSpeakerLabel)
            for (index, chunk) in chunked(transcript).enumerated() {
                let note = try await engine.generate(
                    system: chunkSystem,
                    prompt: chunk,
                    context: ["Part \(index + 1) of a longer meeting."],
                    options: TextGenerationOptions(maxTokens: 1_536))
                notes.append(note)
            }
            // Cap the combined per-part notes so the synthesis prompt fits the
            // model context (lowest-priority/largest parts trimmed first).
            let fitted = PromptSectionBudget().fit(
                sections: notes.enumerated().map {
                    PromptSectionBudget.Section(label: "Part \($0.offset + 1)", text: $0.element,
                                                priority: 1, minCharacters: 200)
                },
                totalBudget: 48_000).map { $0.text }.joined(separator: "\n\n---\n\n")
            body = try await engine.generate(
                system: systemPrompt,
                prompt: "Synthesize the final \(config.noteTemplate.displayName.lowercased()) notes from these per-part notes:\n\n"
                    + fitted,
                context: noteContext,
                options: TextGenerationOptions(maxTokens: 4_096))
        } else {
            body = try await engine.generate(
                system: systemPrompt,
                prompt: PromptTemplates.userPrompt(transcript: text,
                                                   template: config.noteTemplate,
                                                   summaryLanguage: language,
                                                   userSpeakerLabel: userSpeakerLabel),
                context: noteContext,
                options: TextGenerationOptions(maxTokens: 4_096))
        }

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

    /// Outcomes ride behind the summary: same engine, schema-constrained where
    /// the backend supports it (see `OutcomesExtractor`). Failure is non-fatal
    /// — outcomes are an enhancement, never a gate on the meeting artifacts.
    private func extractOutcomes(transcript: Transcript, summary: String,
                                 meetingID: Meeting.ID, folder: URL,
                                 config: AppSettings) async {
        do {
            try Task.checkCancellation()
            let engine = try await makeTextEngine(config)
            let userSpeakerLabel = transcript.displaySpeaker(for: "me")
            let output = try await engine.generate(
                system: OutcomesExtractor.systemPrompt(userSpeakerLabel: userSpeakerLabel),
                prompt: OutcomesExtractor.prompt(transcript: transcript, summary: summary),
                context: MeetingNotes.promptContext(in: folder),
                schema: OutcomesExtractor.schema)
            try Task.checkCancellation()
            guard let outcomes = OutcomesExtractor.parse(
                output,
                userSpeakerLabel: userSpeakerLabel,
                sourceSegments: transcript.segmentSourceMap,
                meetingID: meetingID,
                requireEvidence: true) else {
                lokalbotLog("outcomes extraction unparseable, skipping")
                return
            }
            try Task.checkCancellation()
            let previous = MeetingOutcomes.load(from: folder)
            let previousState = MeetingOutcomeStore.loadState(from: folder)
            try outcomes.write(to: folder)
            if let previous {
                let reconciled = MeetingOutcomeStore.reconcileState(
                    previousState, from: previous, to: outcomes)
                try MeetingOutcomeStore.writeState(reconciled, to: folder)
            }
        } catch {
            lokalbotLog("outcomes extraction failed error=\(error.localizedDescription)")
        }
    }

    /// Cancellation is cooperative; some inference backends may not return
    /// immediately. A failed summary must not let its sibling outcomes task
    /// outlive the job and race a retry's artifact writes.
    nonisolated static func cancelAndWaitForOutcomes(_ task: Task<Void, Never>?) async {
        guard let task else { return }
        task.cancel()
        await task.value
    }

    /// Day digest (M4/M6) — shared by the Timeline UI, scheduler, and
    /// `--digest`. The model writes only the task-first overview. LokalBot
    /// renders the complete chronological activity/meeting log and time table
    /// directly as optional evidence, so filtering summary noise never loses
    /// the underlying workday record.
    func generateDayDigest(
        for day: Date,
        blocks: [ActivityBlock],
        meetings: [Meeting],
        screenContexts: [DayScreenContext],
        config: AppSettings
    ) async throws -> DayDigestGenerationResult {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: blocks,
            screenContexts: screenContexts,
            meetings: dayMeetingEvidence(meetings))

        var warning: String?
        let summary: String
        if evidence.isEmpty {
            summary = DayDigestOverviewGenerator.fallback(evidence)
        } else {
            do {
                try Task.checkCancellation()
                let engine = try await makeTextEngine(config, purpose: "day digest")
                summary = try await generateDayOverview(
                    evidence: evidence,
                    engine: engine,
                    customPrompt: config.dayDigestCustomPrompt)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                warning = "The detailed overview could not be generated: "
                    + error.localizedDescription
                    + " The complete chronological log was still saved."
                summary = DayDigestOverviewGenerator.fallback(evidence)
            }
        }

        try Task.checkCancellation()
        let text = evidence.renderDocument(summary: summary)
        let name = DreamDay.key(for: day)
        let url = storage.rootURL.appendingPathComponent("journal/\(name).md")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return DayDigestGenerationResult(text: text, url: url, summaryWarning: warning)
    }

    /// Code owns evidence coverage and persistence. The model rejects
    /// metadata-only segments, extracts substantive work, and groups it by task.
    private func generateDayOverview(
        evidence: DayDigestEvidence,
        engine: TextEngine,
        customPrompt: String
    ) async throws -> String {
        try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: engine,
            customPrompt: customPrompt)
    }

    private func dayMeetingEvidence(_ meetings: [Meeting]) -> [DayDigestMeetingEvidence] {
        meetings.compactMap { meeting in
            guard let endedAt = meeting.endedAt else { return nil }
            let folder = meeting.folderURL(in: storage)
            let sourceSummary = (try? String(
                contentsOf: folder.appendingPathComponent("summary.md"),
                encoding: .utf8)) ?? ""
            let outcomes = MeetingOutcomes.load(from: folder).map(Self.renderOutcomes) ?? ""
            return DayDigestMeetingEvidence(
                id: meeting.id,
                title: meeting.title,
                app: meeting.appName,
                startedAt: meeting.startedAt,
                endedAt: endedAt,
                sourceSummary: sourceSummary,
                outcomes: outcomes)
        }
    }

    private nonisolated static func renderOutcomes(_ outcomes: MeetingOutcomes) -> String {
        var lines: [String] = []
        if !outcomes.actionItems.isEmpty {
            lines.append("Action items:")
            for item in outcomes.actionItems {
                var details: [String] = []
                if let owner = item.owner, !owner.isEmpty { details.append("owner: \(owner)") }
                if let due = item.due, !due.isEmpty { details.append("due: \(due)") }
                lines.append("- " + item.text
                    + (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"))
            }
        }
        if !outcomes.decisions.isEmpty {
            lines.append("Decisions:")
            lines += outcomes.decisions.map { "- \($0)" }
        }
        if !outcomes.openQuestions.isEmpty {
            lines.append("Open questions:")
            lines += outcomes.openQuestions.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    func makeTextEngine(_ config: AppSettings, server: LlamaServer = .shared,
                        priority: InferencePriority = .background,
                        purpose: String = "summary",
                        broker: InferenceBroker = .shared) async throws -> TextEngine {
        switch config.summarizerBackend {
        case .builtIn:
            guard let entry = ModelCatalog.entry(id: config.builtInModelID,
                                                 custom: config.customBuiltInModels)
                    ?? ModelCatalog.entry(id: ModelCatalog.recommendedSummarizationID) else {
                throw PipelineError.badServerURL
            }
            let modelURL = try await prepareBuiltInModel(config)
            let authenticationToken = await server.authenticationToken()
            let engine = OpenAICompatibleEngine(
                baseURL: server.baseURL,
                model: entry.id,
                apiKey: authenticationToken,
                extraBody: MainLLMRuntimePolicy.requestOverrides(for: entry.id),
                chatDialect: .llamaServer,
                defaultThinkingBudgetTokens:
                    MainLLMRuntimePolicy.highReasoningBudgetTokens,
                displayNameOverride: "Built-in — \(entry.displayName)")
            guard let role = InferenceRole(serverPort: server.port) else {
                // A LlamaServer outside the broker's three roles (never true
                // today) keeps the legacy boot-at-creation path.
                try await server.ensureRunning(modelAt: modelURL)
                return engine
            }
            // The server boots on the first generate call, under a lease that
            // pins it for the duration of each request.
            return LeasedTextEngine(base: engine, broker: broker, role: role,
                                    modelURL: modelURL, priority: priority,
                                    purpose: purpose)
        case .appleIntelligence:
            if case .unavailable(let reason) = FoundationModelAvailability.current() {
                throw TextEngineError.unavailable(reason)
            }
            return AppleIntelligenceEngine()
        case .ollama:
            guard let url = URL(string: config.ollamaBaseURL) else { throw PipelineError.badServerURL }
            try InferenceEndpointPolicy.validate(
                url, approvedOrigins: config.approvedRemoteInferenceOrigins)
            var model = config.ollamaModel
            if model.isEmpty {
                // Zero-config: a running Ollama with any model just works.
                model = await OllamaEngine.listModels(baseURL: url).first ?? ""
            }
            return OllamaEngine(baseURL: url, model: model)
        case .openAICompatible:
            guard let url = URL(string: config.openAIBaseURL) else { throw PipelineError.badServerURL }
            try InferenceEndpointPolicy.validate(
                url, approvedOrigins: config.approvedRemoteInferenceOrigins)
            return OpenAICompatibleEngine(
                baseURL: url,
                model: config.openAIModel,
                apiKey: config.openAIAPIKey,
                chatDialect: .inferred(from: url))
        }
    }

    /// Ensure the selected built-in model is present before the first request.
    /// `ModelDownloadManager` coalesces UI/prewarm/pipeline callers onto one
    /// download, so the first recap waits for preparation instead of failing.
    @discardableResult
    func prepareBuiltInModel(_ config: AppSettings) async throws -> URL {
        guard let entry = ModelCatalog.entry(id: config.builtInModelID,
                                             custom: config.customBuiltInModels)
                ?? ModelCatalog.entry(id: ModelCatalog.recommendedSummarizationID) else {
            throw PipelineError.badServerURL
        }
        // The preparer also validates legacy on-disk models. Bypassing it for a
        // GGUF header match would skip the newly pinned SHA-256 digest.
        return try await builtInModelPreparer(entry, storage)
    }

    /// Split segments into ~12k-char chunks, never mid-segment.
    private func chunked(_ transcript: Transcript) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var length = 0
        for segment in transcript.segments {
            let text = segment.displayText
            guard !text.isEmpty else { continue }
            let line = "**[\(Transcript.stamp(segment.start))] \(transcript.displaySpeaker(for: segment.speaker)):** \(text)"
            if length + line.count > 12_000, !current.isEmpty {
                chunks.append(current.joined(separator: "\n\n"))
                current = []
                length = 0
            }
            current.append(line)
            length += line.count
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n\n")) }
        return chunks
    }

    enum PipelineError: LocalizedError {
        case noAudio, noTranscript, badServerURL
        var errorDescription: String? {
            switch self {
            case .noAudio: "No audio tracks found in the meeting folder."
            case .noTranscript: "No transcript yet — transcribe the meeting first."
            case .badServerURL: "Invalid LLM server URL in Settings → Models."
            }
        }
    }
}
