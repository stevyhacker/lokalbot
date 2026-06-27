import Foundation
import FluidAudio
import Qwen3ASR

/// Qwen3-ASR through Speech Swift's MLX implementation. This is intentionally
/// a post-meeting engine: LokalBot keeps using its existing file-based pipeline,
/// VAD-splits each track into timestamped spans, then transcribes those spans
/// with Qwen.
actor QwenASREngine: TranscriptionEngine {
    enum Variant: Sendable {
        case accuracy
        case compact

        var displayName: String {
            switch self {
            case .accuracy: "Qwen3-ASR 1.7B"
            case .compact: "Qwen3-ASR 0.6B"
            }
        }

        var modelID: String {
            switch self {
            case .accuracy: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
            case .compact: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
            }
        }
    }

    static let accuracy = QwenASREngine(variant: .accuracy)
    static let compact = QwenASREngine(variant: .compact)

    nonisolated var displayName: String { variant.displayName }
    nonisolated let supportsStreaming = false

    private static let sampleRate = 16_000
    private static let maxSegmentSeconds = 15.0

    private let variant: Variant
    private var model: Qwen3ASRModel?
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }

    private init(variant: Variant) {
        self.variant = variant
    }

    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        if model != nil { return }
        report(.init(fractionCompleted: 0, status: "Checking..."), to: progress)
        let cacheDir = try Self.cacheDir(for: variant)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        model = try await Qwen3ASRModel.fromPretrained(
            modelId: variant.modelID,
            cacheDir: cacheDir,
            offlineMode: false
        ) { fraction, status in
            Task { @MainActor in
                progress?(.init(fractionCompleted: fraction, status: status))
            }
        }
        report(.init(fractionCompleted: 1, status: "Ready"), to: progress)
    }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        try await prepare()
        guard let model else { throw EngineError.notLoaded }

        let started = Date()
        let spans = try await Self.spans(for: url)
        var segments: [Transcript.Segment] = []
        for span in spans {
            let text = model.transcribe(
                audio: span.samples,
                sampleRate: Self.sampleRate,
                language: Self.qwenLanguage(language),
                maxTokens: Self.maxTokens(for: span.samples.count))
            let normalized = Transcript.normalizedText(text)
            guard !normalized.isEmpty else { continue }
            segments.append(.init(
                start: span.start,
                end: span.end,
                speaker: "speaker",
                text: normalized,
                confidence: nil))
        }
        let elapsed = Date().timeIntervalSince(started)
        let duration = spans.last?.end ?? 0
        lokalbotLog(
            "qwen-asr profile model=\(variant.modelID) spans=\(spans.count) elapsed=\(String(format: "%.2fs", elapsed)) rtfx=\(String(format: "%.1fx", elapsed > 0 ? duration / elapsed : 0))")
        await idle.bump()
        return Transcript(segments: segments, engine: "\(variant.modelID) (Qwen3ASR MLX)")
    }

    private func unload() {
        model = nil
    }

    private nonisolated func report(_ update: ModelPreparationUpdate,
                                    to handler: ModelPreparationProgressHandler?) {
        guard let handler else { return }
        Task { @MainActor in handler(update) }
    }

    private static func cacheRoot() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppIdentifiers.bundleID, isDirectory: true)
            .appendingPathComponent("qwen3-asr-models", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The directory `Qwen3ASRModel.fromPretrained` both downloads into and
    /// loads from. The Qwen3ASR package's HuggingFace downloader only writes
    /// into a directory shaped like the Hub layout `…/models/<org>/<model>`;
    /// given a flat path its `makeHubApi` fallback silently downloads to
    /// `~/Library/Caches/<root>/models/<org>/<model>` instead, leaving the path
    /// we load from empty ("No safetensors files found"). Building the Hub-style
    /// path under our own root keeps download and load pointed at one directory.
    private static func cacheDir(for variant: Variant) throws -> URL {
        hubStyleCacheDir(base: try cacheRoot(), modelID: variant.modelID)
    }

    /// Pure path arithmetic (no I/O) — `base/models/<org>/<model>` — so the
    /// layout that must match the package's downloader is unit-testable.
    nonisolated static func hubStyleCacheDir(base: URL, modelID: String) -> URL {
        var dir = base.appendingPathComponent("models", isDirectory: true)
        for component in modelID.split(separator: "/") {
            dir = dir.appendingPathComponent(String(component), isDirectory: true)
        }
        return dir
    }

    private struct AudioSpan: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let samples: [Float]
    }

    private static func spans(for url: URL) async throws -> [AudioSpan] {
        if let analysis = await SpeechActivity.shared.speechRegions(in: url),
           !analysis.segments.isEmpty {
            var spans: [AudioSpan] = []
            for segment in analysis.segments {
                let start = max(0, segment.startSample(sampleRate: sampleRate))
                let end = min(analysis.samples.count, segment.endSample(sampleRate: sampleRate))
                guard end > start else { continue }
                spans.append(contentsOf: split(
                    samples: analysis.samples,
                    start: start,
                    end: end,
                    baseTime: 0))
            }
            if !spans.isEmpty { return spans }
        }

        let samples = try AudioConverter().resampleAudioFile(url)
        return split(samples: samples, start: 0, end: samples.count, baseTime: 0)
    }

    private static func split(samples: [Float], start: Int, end: Int,
                              baseTime: TimeInterval) -> [AudioSpan] {
        guard end > start else { return [] }
        let maxSamples = max(1, Int(maxSegmentSeconds * Double(sampleRate)))
        var spans: [AudioSpan] = []
        var cursor = start
        while cursor < end {
            let next = min(cursor + maxSamples, end)
            let startTime = baseTime + Double(cursor) / Double(sampleRate)
            let endTime = baseTime + Double(next) / Double(sampleRate)
            spans.append(.init(
                start: startTime,
                end: endTime,
                samples: Array(samples[cursor..<next])))
            cursor = next
        }
        return spans
    }

    private static func maxTokens(for sampleCount: Int) -> Int {
        let seconds = Double(sampleCount) / Double(sampleRate)
        return min(768, max(128, Int(seconds * 18)))
    }

    private static func qwenLanguage(_ language: String?) -> String? {
        guard let language, language != "auto" else { return nil }
        return language
    }

    enum EngineError: LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded: "Qwen3-ASR failed to load."
            }
        }
    }
}
