import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: AppIdentifiers.appBundleID, category: "NeuralDiarization")

/// Acoustic speaker clustering for microphone and system-audio tracks.
/// Clusters identify distinct voices within a track; confirmation and identity
/// evidence determine whether a voice belongs to the user or someone else.
///
/// Wraps FluidAudio's pyannote-community-1 offline pipeline with the tuned
/// config Seminarly arrived at (threshold 0.70, finer step ratio, low minimum
/// segment duration). Models (~100 MB) are downloaded from Hugging Face on
/// first use and cached by FluidAudio.
@MainActor
final class NeuralDiarizationEngine: ObservableObject {
    @Published private(set) var isPreparing = false
    @Published private(set) var isReady = false
    @Published private(set) var statusMessage = ""

    private var models: OfflineDiarizerModels?

    nonisolated private static func configuration(includeVoiceSamples: Bool) -> OfflineDiarizerConfig {
        // Start from `community-1` defaults, override the knobs that matter
        // for meeting recordings (short interjections, conservative cluster
        // merging, never collapse to one speaker).
        var clustering = OfflineDiarizerConfig.Clustering.community
        clustering.threshold = 0.70     // ↑ stricter merging → more speakers preserved
        clustering.warmStartFa = 0.07   // pyannote default; VBx precision

        var embedding = OfflineDiarizerConfig.Embedding.community
        embedding.minSegmentDurationSeconds = 0.3   // keep brief interjections

        var postProcessing = OfflineDiarizerConfig.PostProcessing.community
        postProcessing.minGapDurationSeconds = 0.05 // tolerate close turns

        var segmentation = OfflineDiarizerConfig.Segmentation.community
        segmentation.stepRatio = 0.15   // finer windows (slower but better recall)

        var config = OfflineDiarizerConfig(
            segmentation: segmentation,
            embedding: embedding,
            clustering: clustering,
            postProcessing: postProcessing)
        config.exposeChunkEmbeddings = includeVoiceSamples
        return config
    }

    /// Download (and cache) the CoreML models. Idempotent — safe to call before
    /// every recording; only the first call hits the network.
    func prepareModels() async {
        guard !isReady, !isPreparing else { return }
        isPreparing = true
        statusMessage = "Downloading speaker models…"
        defer { isPreparing = false }
        do {
            models = try await OfflineDiarizerModels.load()
            isReady = true
            statusMessage = "Speaker models ready"
            ModelRuntimeRegistry.shared.register(
                id: "diarization:pyannote-community-1",
                role: "Speaker diarization",
                label: "Pyannote Community-1",
                estimatedBytes: ModelRuntimeRegistry.gibibytes(0.1)
            )
        } catch {
            statusMessage = "Speaker model load failed: \(error.localizedDescription)"
            logger.error("prepareModels failed: \(error.localizedDescription)")
        }
    }

    /// Run diarization on an audio file. Returns the timeline of speaker
    /// segments FluidAudio identified; an empty list if anything goes wrong
    /// (we never crash the pipeline because of diarization).
    func diarize(url: URL) async -> [DiarizedSegment] {
        await diarizeDetailed(url: url, includeVoiceSamples: false).segments
    }

    func diarizeDetailed(url: URL, includeVoiceSamples: Bool) async -> SpeakerDiarizationResult {
        guard let models else { return .init(segments: [], samples: []) }
        let config = Self.configuration(includeVoiceSamples: includeVoiceSamples)
        return await Task.detached(priority: .utility) {
            do {
                // A light manager per job shares the retained model objects. The
                // opt-in flag affects export only, never segmentation/clustering.
                let manager = OfflineDiarizerManager(config: config)
                manager.initialize(models: models)
                let result = try await manager.process(url)
                let segments = result.segments.map {
                    DiarizedSegment(start: TimeInterval($0.startTimeSeconds),
                                    end: TimeInterval($0.endTimeSeconds), speakerId: $0.speakerId)
                }
                let samples = includeVoiceSamples ? (result.chunkEmbeddings ?? []).map {
                    SpeakerVoiceSample(speaker: $0.speakerId,
                        range: .init(start: $0.startTimeSeconds, end: $0.endTimeSeconds), vector: $0.embedding256)
                } : []
                return SpeakerDiarizationResult(segments: segments, samples: samples)
            } catch {
                logger.error("diarize failed: \(error.localizedDescription)")
                return SpeakerDiarizationResult(segments: [], samples: [])
            }
        }.value
    }

}

/// FluidAudio's segment, distilled to what the pipeline actually uses (start,
/// end, raw speaker id like `"S1"`). Optional voice samples remain private.
struct DiarizedSegment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let speakerId: String
}

extension Array where Element == DiarizedSegment {
    /// Find the FluidAudio segment that overlaps `(start, end)` the most.
    /// Used when relabeling a transcript segment: pick the speaker that
    /// covered most of the spoken interval.
    func dominantSpeaker(coveringStart start: TimeInterval,
                         end: TimeInterval) -> String? {
        var best: (speaker: String, overlap: TimeInterval) = ("", 0)
        for segment in self {
            let overlap = Swift.min(segment.end, end) - Swift.max(segment.start, start)
            guard overlap > 0 else { continue }
            if overlap > best.overlap { best = (segment.speakerId, overlap) }
        }
        return best.overlap > 0 ? best.speaker : nil
    }
}

struct SpeakerDiarizationResult: Sendable {
    var segments: [DiarizedSegment]
    var samples: [SpeakerVoiceSample]
}
