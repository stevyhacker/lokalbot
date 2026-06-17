import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: AppIdentifiers.appBundleID, category: "NeuralDiarization")

/// Acoustic speaker labelling on top of the system-audio track. Mic vs system
/// already tells us "Me" vs "Them"; this engine refines the "Them" side into
/// "Them 1" / "Them 2" / … when several remote participants are on the call.
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

    nonisolated(unsafe) private let diarizer: OfflineDiarizerManager = {
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

        let config = OfflineDiarizerConfig(
            segmentation: segmentation,
            embedding: embedding,
            clustering: clustering,
            postProcessing: postProcessing)
        return OfflineDiarizerManager(config: config)
    }()

    /// Download (and cache) the CoreML models. Idempotent — safe to call before
    /// every recording; only the first call hits the network.
    func prepareModels() async {
        guard !isReady, !isPreparing else { return }
        isPreparing = true
        statusMessage = "Downloading speaker models…"
        defer { isPreparing = false }
        do {
            try await diarizer.prepareModels()
            isReady = true
            statusMessage = "Speaker models ready"
        } catch {
            statusMessage = "Speaker model load failed: \(error.localizedDescription)"
            logger.error("prepareModels failed: \(error.localizedDescription)")
        }
    }

    /// Run diarization on an audio file. Returns the timeline of speaker
    /// segments FluidAudio identified; an empty list if anything goes wrong
    /// (we never crash the pipeline because of diarization).
    nonisolated func diarize(url: URL) async -> [DiarizedSegment] {
        do {
            let result = try await diarizer.process(url)
            return result.segments.map {
                DiarizedSegment(start: TimeInterval($0.startTimeSeconds),
                                end: TimeInterval($0.endTimeSeconds),
                                speakerId: $0.speakerId)
            }
        } catch {
            logger.error("diarize failed: \(error.localizedDescription)")
            return []
        }
    }
}

/// FluidAudio's segment, distilled to what the pipeline actually uses (start,
/// end, raw speaker id like `"S1"`). Embeddings are not surfaced — relabeling
/// only needs timeline overlap.
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
