import Foundation

/// Serial post-meeting queue (design doc §6): transcribe each track,
/// merge by timestamp into a speaker-attributed transcript, then summarize
/// with the configured local LLM. Writes transcript.json / transcript.md /
/// summary.md next to the audio.
@MainActor
final class ProcessingPipeline: ObservableObject {

    enum Stage: Equatable {
        case queued
        case preparingModel      // first run: Parakeet download from Hugging Face
        case transcribing
        case summarizing
        case failed(String)

        var label: String {
            switch self {
            case .queued: "Queued…"
            case .preparingModel: "Preparing transcription model (first run downloads ~600 MB)…"
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
    }

    /// Stage per meeting. `.failed` sticks around until the next attempt;
    /// successful meetings are removed (the files on disk are the result).
    @Published private(set) var stages: [Meeting.ID: Stage] = [:]

    private let storage: StorageManager
    private let settings: () -> AppSettings
    private var queue: [Job] = []
    private var isDraining = false
    private let diarizer = NeuralDiarizationEngine()
    /// Fired after transcript/summary files land on disk (search re-index).
    var onArtifactsWritten: ((Meeting) -> Void)?

    init(storage: StorageManager, settings: @escaping () -> AppSettings) {
        self.storage = storage
        self.settings = settings
    }

    func enqueue(_ meeting: Meeting, transcribe: Bool = true, summarize: Bool = true) {
        queue.append(Job(meeting: meeting, transcribe: transcribe, summarize: summarize))
        stages[meeting.id] = .queued
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
        do {
            if job.transcribe || !FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("transcript.json").path) {
                stages[meeting.id] = .preparingModel
                let choice = config.transcriptionModel
                switch choice {
                case .parakeetV3: await ParakeetEngine.shared.setVariant(.v3)
                case .parakeetV2: await ParakeetEngine.shared.setVariant(.v2)
                default: break
                }
                let engine = choice.engine   // engines prepare lazily inside transcribe

                stages[meeting.id] = .transcribing
                var transcript = try await transcribeTracks(meeting: meeting, folder: folder,
                                                            engine: engine, config: config)
                transcript = await refineSpeakers(transcript: transcript,
                                                  meeting: meeting,
                                                  folder: folder,
                                                  config: config)
                try write(transcript, to: folder)
            }
            if job.summarize {
                stages[meeting.id] = .summarizing
                let transcript = try loadTranscript(from: folder)
                let summary = try await summarize(transcript, meeting: meeting, config: config)
                try summary.data(using: .utf8)?.write(
                    to: folder.appendingPathComponent("summary.md"), options: .atomic)
            }
            stages[meeting.id] = nil
            onArtifactsWritten?(meeting)
        } catch {
            stages[meeting.id] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Transcription

    private func transcribeTracks(meeting: Meeting, folder: URL,
                                  engine: TranscriptionEngine, config: AppSettings) async throws -> Transcript {
        let language = config.transcriptionLanguage.code
        var tracks: [Transcript] = []

        let micURL = folder.appendingPathComponent("mic.m4a")
        if FileManager.default.fileExists(atPath: micURL.path) {
            var t = try await engine.transcribe(audio: micURL, language: language)
            for i in t.segments.indices { t.segments[i].speaker = "me" }
            tracks.append(t)
        }
        let systemURL = folder.appendingPathComponent("system.m4a")
        if meeting.hasSystemTrack, FileManager.default.fileExists(atPath: systemURL.path) {
            var t = try await engine.transcribe(audio: systemURL, language: language)
            for i in t.segments.indices { t.segments[i].speaker = "them" }
            tracks.append(t)
        }
        guard !tracks.isEmpty else {
            throw PipelineError.noAudio
        }
        return Transcript.merged(tracks)
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
        guard config.multiSpeakerDiarization, meeting.hasSystemTrack else { return transcript }
        let systemURL = folder.appendingPathComponent("system.m4a")
        guard FileManager.default.fileExists(atPath: systemURL.path) else { return transcript }
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

    // MARK: - Summarization

    private func summarize(_ transcript: Transcript, meeting: Meeting,
                           config: AppSettings) async throws -> String {
        let engine = try await makeTextEngine(config)
        let text = transcript.markdown
        // Resolve `.matchTranscript` against the transcript text now so both
        // the chunk extractions and the final synthesis share the same
        // language directive (otherwise the chunker can default to English
        // and the reducer flips back).
        let language = SummaryLanguage.resolvedForTranscript(config.summaryLanguage,
                                                             transcript: text)
        let systemPrompt = PromptTemplates.systemPrompt(for: config.noteTemplate,
                                                        summaryLanguage: language)
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
            body = try await engine.generate(
                system: systemPrompt,
                prompt: "Synthesize the final \(config.noteTemplate.displayName.lowercased()) notes from these per-part notes:\n\n"
                    + notes.joined(separator: "\n\n---\n\n"),
                context: [])
        } else {
            body = try await engine.generate(
                system: systemPrompt,
                prompt: PromptTemplates.userPrompt(transcript: text,
                                                   template: config.noteTemplate,
                                                   summaryLanguage: language),
                context: [])
        }

        let date = meeting.startedAt.formatted(date: .long, time: .shortened)
        var header = "# \(meeting.title) — \(date)\n"
        header += "**Duration:** \(meeting.durationLabel) · **App:** \(meeting.appName)"
        header += " · **Template:** \(config.noteTemplate.displayName)"
        if let promptLanguage = language.promptLanguageName {
            header += " · **Language:** \(promptLanguage)"
        }
        header += " · **Model:** \(engine.displayName)\n\n"
        return header + body + "\n"
    }

    /// Day digest (M4/M6) — shared by the Timeline UI and `--digest`.
    func generateDayDigest(for day: Date, blocks: [ActivityBlock], meetings: [Meeting],
                           config: AppSettings) async throws -> (String, URL) {
        let lines = blocks.map {
            "\($0.start.formatted(date: .omitted, time: .shortened))–\($0.end.formatted(date: .omitted, time: .shortened)) \($0.app)\($0.title.isEmpty ? "" : ": \($0.title)") (\(Int($0.duration / 60))m)"
        }
        let meetingLines = meetings.map { "Meeting: \($0.title) (\($0.durationLabel))" }
        let engine = try await makeTextEngine(config)
        let material = (meetingLines + lines).joined(separator: "\n")
        let text = try await engine.generate(
            system: "You summarize a person's workday from their app/window activity log and meeting list. Write Markdown: ## What I worked on (grouped bullets, by project/topic inferred from window titles), ## Meetings (or 'None'), ## Time allocation (one-line table of top apps). Be concrete, never invent.",
            prompt: material.isEmpty ? "No activity was recorded this day." : material,
            context: ["Date: \(day.formatted(date: .complete, time: .omitted))"])
        let name = day.formatted(.iso8601.year().month().day())
        let url = storage.rootURL.appendingPathComponent("journal/\(name).md")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
        return (text, url)
    }

    func makeTextEngine(_ config: AppSettings) async throws -> TextEngine {
        switch config.summarizerBackend {
        case .builtIn:
            guard let entry = ModelCatalog.entry(id: config.builtInModelID)
                    ?? ModelCatalog.entry(id: ModelCatalog.bundledID) else {
                throw PipelineError.badServerURL
            }
            guard let modelURL = ModelCatalog.localURL(for: entry, storage: storage) else {
                throw LlamaServer.ServerError.modelMissing(entry.displayName)
            }
            try await LlamaServer.shared.ensureRunning(modelAt: modelURL)
            return OpenAICompatibleEngine(
                baseURL: LlamaServer.shared.baseURL,
                model: entry.id,
                apiKey: nil,
                extraBody: entry.disablesThinking
                    ? ["chat_template_kwargs": ["enable_thinking": false]] : [:],
                displayNameOverride: "Built-in — \(entry.displayName)")
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
            let line = "**[\(Transcript.stamp(segment.start))] \(segment.speaker.capitalized):** \(segment.text)"
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
