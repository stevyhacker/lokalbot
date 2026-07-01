import Foundation
import FluidAudio
import WhisperKit

struct ModelPreparationUpdate: Sendable {
    var fractionCompleted: Double?
    var status: String
}

typealias ModelPreparationProgressHandler = @MainActor @Sendable (ModelPreparationUpdate) -> Void

private func reportPreparationUpdate(_ update: ModelPreparationUpdate,
                                     to handler: ModelPreparationProgressHandler?) {
    guard let handler else { return }
    Task { @MainActor in handler(update) }
}

private func downloadProgressHandler(
    _ handler: ModelPreparationProgressHandler?
) -> DownloadUtils.ProgressHandler? {
    guard handler != nil else { return nil }
    return { progress in
        let status: String
        switch progress.phase {
        case .listing:
            status = "Checking..."
        case .downloading:
            status = "Downloading..."
        case .compiling:
            status = "Compiling..."
        }
        reportPreparationUpdate(
            .init(fractionCompleted: progress.fractionCompleted, status: status),
            to: handler)
    }
}

/// User-facing transcription model list (Settings). CoreML/MLX families
/// (Parakeet, Qwen3-ASR, Whisper, Cohere) plus ONNX-runtime models for languages
/// those cover poorly — SenseVoice (CJK) and GigaAM (Russian) — via the bundled
/// sherpa-onnx engine.
enum TranscriptionModelChoice: String, Codable, CaseIterable, Identifiable {
    case parakeetV3 = "Parakeet TDT 0.6B v3 (multilingual)"
    case parakeetV2 = "Parakeet TDT 0.6B v2 (English)"
    case qwenASR17B = "Qwen3-ASR 1.7B"
    case qwenASR06B = "Qwen3-ASR 0.6B"
    case graniteSpeech = "Granite Speech 4.1 2B"
    case whisperLarge = "Whisper large-v3 turbo"
    case cohere = "Cohere Transcribe (multilingual)"
    case senseVoice = "SenseVoice (Chinese/Japanese/Korean)"
    case gigaamRussian = "GigaAM (Russian)"
    var id: String { rawValue }
    static let recommended: Self = .graniteSpeech

    var blurb: String {
        switch self {
        case .parakeetV3: "0.6 GB · 25 European languages, ~190× realtime"
        case .parakeetV2: "0.6 GB · English only, slightly higher recall"
        case .qwenASR17B: "3.2 GB · MLX, 52 languages/dialects, best Qwen accuracy tier"
        case .qwenASR06B: "0.7 GB · MLX, 52 languages/dialects, compact global tier"
        case .graniteSpeech: "2B params · Apache-2.0, recommended local ASR via llama.cpp"
        case .whisperLarge: "1.6 GB · 99 languages, word timestamps, wide-language legacy fallback"
        case .cohere: "2B params · 14 languages, no auto language detection, timestamps, or diarization"
        case .senseVoice: "Chinese · Japanese · Korean · Cantonese · English (ONNX, downloaded on first use)"
        case .gigaamRussian: "Russian — high accuracy (ONNX, downloaded on first use)"
        }
    }

    var engine: TranscriptionEngine {
        switch self {
        case .parakeetV3, .parakeetV2: ParakeetEngine.shared
        case .qwenASR17B: QwenASREngine.accuracy
        case .qwenASR06B: QwenASREngine.compact
        case .graniteSpeech: GraniteSpeechEngine.shared
        case .whisperLarge: WhisperEngine.shared
        case .cohere: CohereEngine.shared
        case .senseVoice: OnnxTranscriptionEngine.senseVoice
        case .gigaamRussian: OnnxTranscriptionEngine.gigaamRussian
        }
    }
}

/// M2 contract (design doc §5). The app talks only to these protocols;
/// engines (Parakeet, WhisperKit, whisper.cpp, VibeVoice) plug in behind.
protocol TranscriptionEngine {
    var displayName: String { get }
    var supportsStreaming: Bool { get }
    func transcribe(audio: URL, language: String?) async throws -> Transcript
}

/// Releases an idle, expensive resource (a loaded transcription model) after a
/// quiet period — mirrors Handy's idle-unload so a long-running app doesn't pin
/// hundreds of MB to >1 GB of CoreML weights between meetings. Call `bump()`
/// after each use; `onIdle` runs only if nothing bumped during the interval.
actor IdleTimer {
    private let seconds: TimeInterval
    private let onIdle: @Sendable () async -> Void
    private var generation = 0

    init(seconds: TimeInterval, onIdle: @escaping @Sendable () async -> Void) {
        self.seconds = seconds
        self.onIdle = onIdle
    }

    func bump() {
        generation += 1
        let scheduled = generation
        let delay = seconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.fireIfIdle(scheduled)
        }
    }

    private func fireIfIdle(_ scheduled: Int) async {
        guard scheduled == generation else { return }   // a newer use bumped us
        await onIdle()
    }
}


/// Parakeet TDT 0.6B via FluidAudio — CoreML, in-process, runs on the
/// Neural Engine (~190x realtime on M4). v3 = 25 European languages,
/// v2 = English-only with higher recall. The model (~600 MB) is fetched
/// from Hugging Face on first use and cached; the only network access.
actor ParakeetEngine: TranscriptionEngine {

    enum Variant: String, Codable, CaseIterable, Identifiable, Sendable {
        case v3 = "Parakeet TDT 0.6B v3 (multilingual)"
        case v2 = "Parakeet TDT 0.6B v2 (English)"
        var id: String { rawValue }
        var modelVersion: AsrModelVersion { self == .v3 ? .v3 : .v2 }
    }

    static let shared = ParakeetEngine()

    nonisolated let displayName = "Parakeet TDT 0.6B"
    nonisolated let supportsStreaming = false

    private var manager: AsrManager?
    private var loadedVariant: Variant?
    private(set) var variant: Variant = .v3
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }

    func setVariant(_ v: Variant) { variant = v }

    /// Downloads (first run) and loads the CoreML model. Idempotent.
    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        guard manager == nil || loadedVariant != variant else { return }
        reportPreparationUpdate(.init(fractionCompleted: nil, status: "Checking..."),
                                to: progress)
        let models = try await AsrModels.downloadAndLoad(
            version: variant.modelVersion,
            progressHandler: downloadProgressHandler(progress))
        reportPreparationUpdate(.init(fractionCompleted: nil, status: "Loading..."),
                                to: progress)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        manager = m
        loadedVariant = variant
        reportPreparationUpdate(.init(fractionCompleted: 1, status: "Ready"), to: progress)
    }

    /// Free the loaded model after an idle period (driven by `idle`).
    private func unload() { manager = nil; loadedVariant = nil }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        try await prepare()
        guard let manager else { throw EngineError.notLoaded }
        var state = try TdtDecoderState()
        let hint = language.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(url, decoderState: &state, language: hint)
        let transcript = Transcript(segments: Self.segments(from: result, speaker: "speaker"),
                                    engine: "\(loadedVariant == .v2 ? "parakeet-tdt-0.6b-v2" : "parakeet-tdt-0.6b-v3") (FluidAudio)")
        await idle.bump()
        return transcript
    }

    enum EngineError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "Transcription model failed to load." }
    }

    // MARK: - Token timings → readable segments

    /// Group plain text into one segment per track when an engine has no
    /// timestamps (Cohere). Track-level Me/Them attribution still works.
    static func singleSegment(text: String, duration: TimeInterval,
                              speaker: String) -> [Transcript.Segment] {
        let trimmed = Transcript.normalizedText(text)
        guard !trimmed.isEmpty else { return [] }
        return [Transcript.Segment(start: 0, end: duration, speaker: speaker,
                                   text: trimmed, confidence: nil)]
    }

    /// Groups token timings into sentence-ish segments: split on silence
    /// gaps > 1 s, on sentence-ending punctuation once a segment has grown
    /// past ~200 chars, or after 30 s regardless.
    static func segments(from result: ASRResult, speaker: String) -> [Transcript.Segment] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            let text = Transcript.normalizedText(result.text)
            guard !text.isEmpty else { return [] }
            return [Transcript.Segment(start: 0, end: result.duration, speaker: speaker,
                                       text: text, confidence: Double(result.confidence))]
        }

        var out: [Transcript.Segment] = []
        var current: [TokenTiming] = []
        var currentLength = 0

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = Transcript.normalizedText(current.map(\.token).joined()
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines))
            if !text.isEmpty {
                let conf = current.map { Double($0.confidence) }.reduce(0, +) / Double(current.count)
                out.append(.init(start: first.startTime, end: last.endTime,
                                 speaker: speaker, text: text, confidence: conf))
            }
            current = []
            currentLength = 0
        }

        for timing in timings {
            if let last = current.last, let first = current.first {
                let gap = timing.startTime - last.endTime
                let duration = last.endTime - first.startTime
                let sentenceEnded = last.token.hasSuffix(".") || last.token.hasSuffix("!")
                    || last.token.hasSuffix("?")
                if gap > 1.0 || duration > 30 || (sentenceEnded && currentLength > 200) {
                    flush()
                }
            }
            current.append(timing)
            currentLength += timing.token.count
        }
        flush()
        return out
    }
}

/// Whisper large-v3 turbo via WhisperKit (CoreML, ~1.6 GB, auto-downloaded
/// from Hugging Face on first use). 99 languages, real segment timestamps.
actor WhisperEngine: TranscriptionEngine {
    static let shared = WhisperEngine()
    nonisolated let displayName = "Whisper large-v3 turbo"
    nonisolated let supportsStreaming = false

    private var pipe: WhisperKit?
    private let modelName = "large-v3-v20240930"
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }

    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        guard pipe == nil else { return }
        reportPreparationUpdate(.init(fractionCompleted: nil, status: "Checking..."),
                                to: progress)
        let modelFolder = try await WhisperKit.download(variant: modelName) { download in
            reportPreparationUpdate(
                .init(fractionCompleted: download.fractionCompleted,
                      status: "Downloading..."),
                to: progress)
        }
        reportPreparationUpdate(.init(fractionCompleted: nil, status: "Loading..."),
                                to: progress)
        pipe = try await WhisperKit(WhisperKitConfig(
            model: modelName,
            modelFolder: modelFolder.path(percentEncoded: false),
            download: false))
        reportPreparationUpdate(.init(fractionCompleted: 1, status: "Ready"), to: progress)
    }

    private func unload() { pipe = nil }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        try await prepare()
        guard let pipe else { throw ParakeetEngine.EngineError.notLoaded }
        let options = DecodingOptions(language: language, detectLanguage: language == nil)
        let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
        let segments = results.flatMap(\.segments).map { seg in
            Transcript.Segment(start: TimeInterval(seg.start), end: TimeInterval(seg.end),
                               speaker: "speaker",
                               text: Transcript.normalizedText(seg.text),
                               confidence: nil)
        }.filter { !$0.text.isEmpty }
        await idle.bump()
        return Transcript(segments: segments, engine: "whisper-large-v3-turbo (WhisperKit)")
    }
}

/// Cohere Transcribe (03-2026) via FluidAudio — CoreML int8, 14 languages.
/// The model emits no timestamps, so each track is split into VAD speech regions
/// and transcribed per region, giving real per-utterance timing (with a
/// whole-track single-segment fallback when VAD is unavailable).
actor CohereEngine: TranscriptionEngine {
    static let shared = CohereEngine()
    nonisolated let displayName = "Cohere Transcribe"
    nonisolated let supportsStreaming = false

    private var models: CoherePipeline.LoadedModels?
    private let pipeline = CoherePipeline()
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }

    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        guard models == nil else { return }
        reportPreparationUpdate(.init(fractionCompleted: nil, status: "Checking..."),
                                to: progress)
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
        let repoDir = base.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName)
        if !FileManager.default.fileExists(
            atPath: repoDir.appendingPathComponent(ModelNames.CohereTranscribe.encoderCompiledFile).path) {
            try await DownloadUtils.downloadRepo(
                .cohereTranscribeCoreml,
                to: base,
                progressHandler: downloadProgressHandler(progress))
        }
        reportPreparationUpdate(.init(fractionCompleted: nil, status: "Loading..."),
                                to: progress)
        models = try await CoherePipeline.loadModels(
            encoderDir: repoDir, decoderDir: repoDir, vocabDir: repoDir)
        reportPreparationUpdate(.init(fractionCompleted: 1, status: "Ready"), to: progress)
    }

    private func unload() { models = nil }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        try await prepare()
        guard let models else { throw ParakeetEngine.EngineError.notLoaded }
        let lang = language.flatMap { CohereAsrConfig.Language(rawValue: $0) } ?? .english
        let sampleRate = CohereAsrConfig.sampleRate

        // Cohere returns no timestamps, so transcribe each VAD speech region
        // (≤14 s) on its own and stamp it with the region's real start/end —
        // real per-utterance timing without forced alignment. Falls back to one
        // whole-track segment if VAD is unavailable or finds no regions.
        if let analysis = await SpeechActivity.shared.speechRegions(in: url),
           !analysis.segments.isEmpty {
            let started = Date()
            var segments: [Transcript.Segment] = []
            for region in analysis.segments {
                let lo = max(0, region.startSample(sampleRate: sampleRate))
                let hi = min(analysis.samples.count, region.endSample(sampleRate: sampleRate))
                guard hi > lo else { continue }
                let chunk = Array(analysis.samples[lo..<hi])
                let result = try await pipeline.transcribe(audio: chunk, models: models, language: lang)
                let text = Transcript.normalizedText(result.text)
                if !text.isEmpty {
                    segments.append(.init(start: region.startTime, end: region.endTime,
                                          speaker: "speaker", text: text, confidence: nil))
                }
            }
            if !segments.isEmpty {
                let total = Double(analysis.samples.count) / Double(sampleRate)
                let elapsed = Date().timeIntervalSince(started)
                lokalbotLog(
                    "cohere profile mode=vad-segmented duration=\(Self.formatSeconds(total)) regions=\(analysis.segments.count) segments=\(segments.count) elapsed=\(Self.formatSeconds(elapsed)) rtfx=\(Self.formatMultiplier(elapsed > 0 ? total / elapsed : 0)) language=\(lang.rawValue)")
                await idle.bump()
                return Transcript(segments: segments,
                                  engine: "cohere-transcribe-03-2026 (FluidAudio, vad-segmented)")
            }
        }

        // Fallback: whole track as one segment (no timestamps).
        let conversionStarted = Date()
        let samples = try AudioConverter().resampleAudioFile(url)
        let conversionSeconds = Date().timeIntervalSince(conversionStarted)
        let duration = Double(samples.count) / Double(sampleRate)
        let pipelineStarted = Date()
        let result = try await pipeline.transcribeLong(audio: samples, models: models, language: lang)
        let pipelineSeconds = Date().timeIntervalSince(pipelineStarted)
        let totalSeconds = conversionSeconds + pipelineSeconds
        let rtfx = totalSeconds > 0 ? duration / totalSeconds : 0
        lokalbotLog(
            "cohere profile mode=whole-track duration=\(Self.formatSeconds(duration)) convert=\(Self.formatSeconds(conversionSeconds)) pipeline=\(Self.formatSeconds(pipelineSeconds)) encoder=\(Self.formatSeconds(result.encoderSeconds)) decoder=\(Self.formatSeconds(result.decoderSeconds)) total=\(Self.formatSeconds(totalSeconds)) rtfx=\(Self.formatMultiplier(rtfx)) language=\(lang.rawValue)")
        await idle.bump()
        return Transcript(
            segments: ParakeetEngine.singleSegment(text: result.text, duration: duration,
                                                   speaker: "speaker"),
            engine: "cohere-transcribe-03-2026 (FluidAudio)")
    }

    private nonisolated static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.2fs", seconds)
    }

    private nonisolated static func formatMultiplier(_ value: Double) -> String {
        String(format: "%.2fx", value)
    }
}

/// Voice-activity gate over FluidAudio's Silero VAD. Lets the pipeline skip
/// transcribing a track with no speech (e.g. your mic while muted for the whole
/// call) rather than feeding silence to the ASR model, which can hallucinate
/// text. Conservative: any error/uncertainty reports speech so a real track is
/// never dropped. Idle-unloads the (small) VAD model like the ASR engines.
actor SpeechActivity {
    static let shared = SpeechActivity()

    private var manager: VadManager?
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }

    /// Decode `url` to 16 kHz mono and split it into ≤14 s speech regions
    /// (Silero VAD, ASR-tuned `.default` config). Returns the samples plus the
    /// timed regions, or nil when VAD is unavailable. Each region carries a real
    /// `startTime`/`endTime`, which lets timestamp-less engines (Cohere) emit
    /// per-region segments instead of one block per track.
    func speechRegions(in url: URL) async -> (samples: [Float], segments: [VadSegment])? {
        do {
            try await prepare()
            guard let manager else { return nil }
            let samples = try AudioConverter().resampleAudioFile(url)
            let segments = try await manager.segmentSpeech(samples)
            await idle.bump()
            return (samples, segments)
        } catch {
            lokalbotLog("vad unavailable — transcribing without it: \(error.localizedDescription)")
            return nil
        }
    }

    /// Total seconds of detected speech in `url`, or nil when VAD is
    /// unavailable — in which case the caller should transcribe anyway.
    func speechSeconds(in url: URL) async -> Double? {
        await speechRegions(in: url)?.segments.reduce(0.0) { $0 + $1.duration }
    }

    private func prepare() async throws {
        guard manager == nil else { return }
        manager = try await VadManager()
    }

    private func unload() { manager = nil }
}
