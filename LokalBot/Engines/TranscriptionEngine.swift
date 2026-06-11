import Foundation
import FluidAudio
import WhisperKit

/// User-facing transcription model list (Settings). Same families Handy
/// ships: Parakeet (CoreML), Whisper (WhisperKit/CoreML), Cohere (CoreML).
enum TranscriptionModelChoice: String, Codable, CaseIterable, Identifiable {
    case parakeetV3 = "Parakeet TDT 0.6B v3 (multilingual)"
    case parakeetV2 = "Parakeet TDT 0.6B v2 (English)"
    case whisperLarge = "Whisper large-v3 turbo"
    case cohere = "Cohere Transcribe (multilingual)"
    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .parakeetV3: "0.6 GB · 25 European languages, ~190× realtime — recommended"
        case .parakeetV2: "0.6 GB · English only, slightly higher recall"
        case .whisperLarge: "1.6 GB · 99 languages, word timestamps, the accuracy benchmark"
        case .cohere: "1.7 GB · 23 languages incl. CJK/Arabic. No per-sentence timestamps yet"
        }
    }

    var engine: TranscriptionEngine {
        switch self {
        case .parakeetV3, .parakeetV2: ParakeetEngine.shared
        case .whisperLarge: WhisperEngine.shared
        case .cohere: CohereEngine.shared
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

struct Transcript: Codable {
    struct Segment: Codable {
        var start: TimeInterval
        var end: TimeInterval
        var speaker: String      // "me" | "them" | diarized label
        var text: String
        var confidence: Double?
    }
    var segments: [Segment]
    var engine: String

    /// Renders `transcript.md` — "[00:14:32] **Me:** …"
    var markdown: String {
        segments.map { seg in
            "**[\(Self.stamp(seg.start))] \(seg.speaker.capitalized):** \(seg.text)"
        }.joined(separator: "\n\n")
    }

    /// Merge per-track transcripts (mic = "me", system = "them") by timestamp.
    static func merged(_ tracks: [Transcript]) -> Transcript {
        Transcript(
            segments: tracks.flatMap(\.segments).sorted { $0.start < $1.start },
            engine: tracks.first?.engine ?? "unknown")
    }

    static func stamp(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
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

    func setVariant(_ v: Variant) { variant = v }

    /// Downloads (first run) and loads the CoreML model. Idempotent.
    func prepare() async throws {
        guard manager == nil || loadedVariant != variant else { return }
        let models = try await AsrModels.downloadAndLoad(version: variant.modelVersion)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        manager = m
        loadedVariant = variant
    }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        try await prepare()
        guard let manager else { throw EngineError.notLoaded }
        var state = try TdtDecoderState()
        let hint = language.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(url, decoderState: &state, language: hint)
        return Transcript(segments: Self.segments(from: result, speaker: "speaker"),
                          engine: "\(loadedVariant == .v2 ? "parakeet-tdt-0.6b-v2" : "parakeet-tdt-0.6b-v3") (FluidAudio)")
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [Transcript.Segment(start: 0, end: duration, speaker: speaker,
                                   text: trimmed, confidence: nil)]
    }

    /// Groups token timings into sentence-ish segments: split on silence
    /// gaps > 1 s, on sentence-ending punctuation once a segment has grown
    /// past ~200 chars, or after 30 s regardless.
    static func segments(from result: ASRResult, speaker: String) -> [Transcript.Segment] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [Transcript.Segment(start: 0, end: result.duration, speaker: speaker,
                                       text: text, confidence: Double(result.confidence))]
        }

        var out: [Transcript.Segment] = []
        var current: [TokenTiming] = []
        var currentLength = 0

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.token).joined()
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
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

    func prepare() async throws {
        guard pipe == nil else { return }
        pipe = try await WhisperKit(WhisperKitConfig(model: "large-v3-v20240930"))
    }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        try await prepare()
        guard let pipe else { throw ParakeetEngine.EngineError.notLoaded }
        let options = DecodingOptions(language: language, detectLanguage: language == nil)
        let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
        let segments = results.flatMap(\.segments).map { seg in
            Transcript.Segment(start: TimeInterval(seg.start), end: TimeInterval(seg.end),
                               speaker: "speaker",
                               text: seg.text.trimmingCharacters(in: .whitespacesAndNewlines),
                               confidence: nil)
        }.filter { !$0.text.isEmpty }
        return Transcript(segments: segments, engine: "whisper-large-v3-turbo (WhisperKit)")
    }
}

/// Cohere Transcribe (03-2026) via FluidAudio — CoreML int8, 23 languages
/// incl. CJK/Arabic. The model has no token timestamps, so each track
/// becomes one segment (Me/Them attribution still applies).
actor CohereEngine: TranscriptionEngine {
    static let shared = CohereEngine()
    nonisolated let displayName = "Cohere Transcribe"
    nonisolated let supportsStreaming = false

    private var models: CoherePipeline.LoadedModels?
    private let pipeline = CoherePipeline()

    func prepare() async throws {
        guard models == nil else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
        let repoDir = base.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName)
        if !FileManager.default.fileExists(
            atPath: repoDir.appendingPathComponent(ModelNames.CohereTranscribe.encoderCompiledFile).path) {
            try await DownloadUtils.downloadRepo(.cohereTranscribeCoreml, to: base)
        }
        models = try await CoherePipeline.loadModels(
            encoderDir: repoDir, decoderDir: repoDir, vocabDir: repoDir)
    }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        try await prepare()
        guard let models else { throw ParakeetEngine.EngineError.notLoaded }
        let samples = try AudioConverter().resampleAudioFile(url)
        let duration = Double(samples.count) / Double(CohereAsrConfig.sampleRate)
        let lang = language.flatMap { CohereAsrConfig.Language(rawValue: $0) } ?? .english
        let result = try await pipeline.transcribeLong(audio: samples, models: models,
                                                       language: lang)
        return Transcript(
            segments: ParakeetEngine.singleSegment(text: result.text, duration: duration,
                                                   speaker: "speaker"),
            engine: "cohere-transcribe-03-2026 (FluidAudio)")
    }
}
