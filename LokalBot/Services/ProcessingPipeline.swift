import Foundation

/// Serial post-meeting queue (design doc §6): transcribe each track,
/// merge by timestamp into a speaker-attributed transcript, then summarize
/// with the configured local LLM. Writes transcript.json / transcript.md /
/// summary.md next to the audio.
@MainActor
final class ProcessingPipeline: ObservableObject {

    enum Stage: Equatable {
        case queued
        case preparingModel      // first run: selected model download from Hugging Face
        case transcribing
        case summarizing
        case failed(String)

        var label: String {
            switch self {
            case .queued: "Queued…"
            case .preparingModel: "Preparing transcription model (download size depends on your selection)…"
            case .transcribing: "Transcribing…"
            case .summarizing: "Summarizing…"
            case .failed(let message): "Failed: \(message)"
            }
        }
    }

    struct Job {
        var meeting: Meeting
        var transcribe: Bool
        var summarize: Bool
        /// Re-enqueued from the persisted queue after a crash/quit — keep any
        /// per-track checkpoints instead of starting from scratch.
        var resumed: Bool = false
    }

    /// Stage per meeting. `.failed` sticks around until the next attempt;
    /// successful meetings are removed (the files on disk are the result).
    @Published private(set) var stages: [Meeting.ID: Stage] = [:]

    private let storage: StorageManager
    private let settings: () -> AppSettings
    /// In-memory work list; `jobStore` mirrors it on disk so a crash mid-queue
    /// loses nothing — see `resumePending(meetings:)`.
    private var queue: [Job] = []
    private var isDraining = false
    private let diarizer = NeuralDiarizationEngine()
    private let jobStore: PipelineJobStore?
    /// Fired after transcript/summary files land on disk (search re-index).
    var onArtifactsWritten: ((Meeting) -> Void)?

    init(storage: StorageManager, jobStore: PipelineJobStore? = nil,
         settings: @escaping () -> AppSettings) {
        self.storage = storage
        self.jobStore = jobStore
        self.settings = settings
    }

    func enqueue(_ meeting: Meeting, transcribe: Bool = true, summarize: Bool = true) {
        jobStore?.enqueue(meetingID: meeting.id, transcribe: transcribe, summarize: summarize)
        queue.append(Job(meeting: meeting, transcribe: transcribe, summarize: summarize))
        stages[meeting.id] = .queued
        drain()
    }

    /// Crash recovery, called once at launch: re-enqueue every persisted job
    /// that never reached completion. Jobs whose transcript already made it to
    /// disk skip straight to summarization; jobs that burned through
    /// `PipelineJobStore.maxAutoResumeAttempts` starts stay parked until the
    /// user retries explicitly — a meeting that reliably kills the app must
    /// not crash-loop every launch.
    func resumePending(meetings: [Meeting]) {
        guard let jobStore else { return }
        jobStore.prune(existing: Set(meetings.map(\.id)))
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
                             resumed: true))
            stages[meeting.id] = .queued
        }
        drain()
    }

    private func drain() {
        guard !isDraining else { return }
        isDraining = true
        Task {
            while !queue.isEmpty {
                let job = queue.removeFirst()
                await process(job)
            }
            isDraining = false
        }
    }

    private func process(_ job: Job) async {
        let meeting = job.meeting
        let folder = meeting.folderURL(in: storage)
        let config = settings()
        jobStore?.markStarted(meetingID: meeting.id)
        // Live-preview tees are deleted when a recording stops; sweep any a
        // crash left behind so they don't sit next to the real tracks forever.
        for name in [AudioPreviewTee.micFileName, AudioPreviewTee.systemFileName] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        do {
            if job.transcribe || !FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("transcript.json").path) {
                // A fresh enqueue means "transcribe with today's settings" —
                // stale checkpoints from an earlier failed attempt may have
                // been produced by a different model. Only a crash resume
                // trusts them.
                if !job.resumed { clearCheckpoints(in: folder) }
                stages[meeting.id] = .preparingModel
                let engine = config.transcriptionModel.engine   // engines prepare lazily inside transcribe

                stages[meeting.id] = .transcribing
                var transcript = try await transcribeTracks(meeting: meeting, folder: folder,
                                                            engine: engine, config: config)
                transcript = await refineSpeakers(transcript: transcript,
                                                  meeting: meeting,
                                                  folder: folder,
                                                  config: config)
                transcript = SpeakerAutoNamer.applyingAliases(
                    to: transcript, participantNames: meeting.participantNameHints ?? [])
                try write(transcript, to: folder)
                clearCheckpoints(in: folder)
            }
            if job.summarize {
                stages[meeting.id] = .summarizing
                let transcript = try loadTranscript(from: folder)
                let summary: String
                do {
                    summary = try await summarize(transcript, meeting: meeting, config: config)
                } catch {
                    // One automatic retry: summarization failures are usually
                    // transient (server still warming up, brief memory
                    // pressure) and the expensive transcription work is
                    // already safely on disk.
                    lokalbotLog("summary retry after error=\(error.localizedDescription)")
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    summary = try await summarize(transcript, meeting: meeting, config: config)
                }
                try summary.data(using: .utf8)?.write(
                    to: folder.appendingPathComponent("summary.md"), options: .atomic)
                await extractOutcomes(transcript: transcript, summary: summary, folder: folder,
                                      config: config)
            }
            stages[meeting.id] = nil
            jobStore?.markCompleted(meetingID: meeting.id)
            onArtifactsWritten?(meeting)
        } catch {
            // The persisted job row stays — the next launch re-enqueues it
            // (until the attempt cap) so a crash or transient failure never
            // silently drops a meeting.
            stages[meeting.id] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Transcription

    private func transcribeTracks(meeting: Meeting, folder: URL,
                                  engine: TranscriptionEngine, config: AppSettings) async throws -> Transcript {
        let language = config.transcriptionLanguage.code
        var tracks: [Transcript] = []
        var trackError: Error?

        for (name, speaker) in [("mic", "me"), ("system", "them")] {
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
                let url = folder.appendingPathComponent("\(name).m4a")
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
                                config: AppSettings) async -> Transcript {
        guard config.multiSpeakerDiarization else { return transcript }
        let systemURL = folder.appendingPathComponent("system.m4a")
        guard AudioFileInspector.isTranscribableAudio(at: systemURL) else { return transcript }
        await diarizer.prepareModels()
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
        let systemPrompt = PromptTemplates.systemPrompt(for: config.noteTemplate,
                                                        summaryLanguage: language)
        // Quick notes the user typed during the meeting ride along as context
        // in the final pass (both paths) — they're the user's own words, so
        // the summary should fold them in rather than rediscover them.
        let noteContext = MeetingNotes.promptContext(in: meeting.folderURL(in: storage))
        let body: String

        // Map-reduce long meetings: per-chunk notes, then one synthesis pass.
        if text.count > 24_000 {
            var notes: [String] = []
            let chunkSystem = PromptTemplates.chunkExtractionSystem(summaryLanguage: language)
            for (index, chunk) in chunked(transcript).enumerated() {
                let note = try await engine.generate(
                    system: chunkSystem,
                    prompt: chunk,
                    context: ["Part \(index + 1) of a longer meeting."])
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
                context: noteContext)
        } else {
            body = try await engine.generate(
                system: systemPrompt,
                prompt: PromptTemplates.userPrompt(transcript: text,
                                                   template: config.noteTemplate,
                                                   summaryLanguage: language),
                context: noteContext)
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
                                 folder: URL, config: AppSettings) async {
        do {
            let engine = try await makeTextEngine(config)
            let output = try await engine.generate(
                system: OutcomesExtractor.systemPrompt,
                prompt: OutcomesExtractor.prompt(transcriptMarkdown: transcript.markdown,
                                                 summary: summary),
                context: MeetingNotes.promptContext(in: folder),
                schema: OutcomesExtractor.schema)
            guard let outcomes = OutcomesExtractor.parse(output) else {
                lokalbotLog("outcomes extraction unparseable, skipping")
                return
            }
            try outcomes.write(to: folder)
        } catch {
            lokalbotLog("outcomes extraction failed error=\(error.localizedDescription)")
        }
    }

    /// Day digest (M4/M6) — shared by the Timeline UI and `--digest`. `ocr` is
    /// the day's OCR'd screen text from periodic screenshots; it carries the
    /// on-screen detail window titles alone can't (what was actually read,
    /// written, or discussed), so the summary isn't limited to app/title names.
    func generateDayDigest(for day: Date, blocks: [ActivityBlock], meetings: [Meeting],
                           ocr: String, config: AppSettings) async throws -> (String, URL) {
        let lines = blocks.map {
            "\($0.start.formatted(date: .omitted, time: .shortened))–\($0.end.formatted(date: .omitted, time: .shortened)) \($0.app)\($0.title.isEmpty ? "" : ": \($0.title)") (\(Int($0.duration / 60))m)"
        }
        let meetingLines = meetings.map { "Meeting: \($0.title) (\($0.durationLabel))" }
        let engine = try await makeTextEngine(config)
        let material = PromptContextSanitizer.sanitize(
            (meetingLines + lines).joined(separator: "\n"), maxCharacters: 24_000)
        let context = Self.digestContext(date: day, ocr: ocr)
        let text = try await engine.generate(
            system: PromptTemplates.dayDigestSystem,
            prompt: material.isEmpty ? "No activity was recorded this day." : material,
            context: context)
        let name = day.formatted(.iso8601.year().month().day())
        let url = storage.rootURL.appendingPathComponent("journal/\(name).md")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
        return (text, url)
    }

    /// LLM context blocks for a day digest: the date plus — when present — the
    /// OCR'd screen text from the day's screenshots. The OCR block is what lets
    /// the digest reflect actual on-screen content, not just window titles.
    /// Pure + `nonisolated static` so the screenshot→digest wiring is unit-
    /// testable without a model, mirroring `AppleIntelligenceEngine.composePrompt`.
    nonisolated static func digestContext(date: Date, ocr: String) -> [String] {
        var context = ["Date: \(date.formatted(date: .complete, time: .omitted))"]
        let screenText = PromptContextSanitizer.sanitize(ocr, maxCharacters: 12_000)
        if !screenText.isEmpty {
            context.append("Screen text OCR'd from periodic screenshots:\n" + screenText)
        }
        return context
    }

    func makeTextEngine(_ config: AppSettings, server: LlamaServer = .shared) async throws -> TextEngine {
        switch config.summarizerBackend {
        case .builtIn:
            guard let entry = ModelCatalog.entry(id: config.builtInModelID,
                                                 custom: config.customBuiltInModels)
                    ?? ModelCatalog.entry(id: ModelCatalog.recommendedSummarizationID) else {
                throw PipelineError.badServerURL
            }
            guard let modelURL = ModelCatalog.localURL(for: entry, storage: storage) else {
                throw LlamaServer.ServerError.modelMissing(entry.displayName)
            }
            try await server.ensureRunning(modelAt: modelURL)
            return OpenAICompatibleEngine(
                baseURL: server.baseURL,
                model: entry.id,
                apiKey: nil,
                extraBody: entry.disablesThinking
                    ? ["chat_template_kwargs": ["enable_thinking": false]] : [:],
                displayNameOverride: "Built-in — \(entry.displayName)")
        case .appleIntelligence:
            if case .unavailable(let reason) = FoundationModelAvailability.current() {
                throw TextEngineError.unavailable(reason)
            }
            return AppleIntelligenceEngine()
        case .ollama:
            guard let url = URL(string: config.ollamaBaseURL) else { throw PipelineError.badServerURL }
            var model = config.ollamaModel
            if model.isEmpty {
                // Zero-config: a running Ollama with any model just works.
                model = await OllamaEngine.listModels(baseURL: url).first ?? ""
            }
            return OllamaEngine(baseURL: url, model: model)
        case .openAICompatible:
            guard let url = URL(string: config.openAIBaseURL) else { throw PipelineError.badServerURL }
            return OpenAICompatibleEngine(baseURL: url, model: config.openAIModel,
                                          apiKey: config.openAIAPIKey)
        }
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
