import Foundation

/// Chunking decisions for the live meeting transcript, kept pure for unit
/// tests. The transcriber re-reads a growing PCM tee and feeds bounded chunks
/// to the ASR engine; these helpers decide *where* to cut so chunks stay
/// small enough to transcribe in near-real-time and cuts land in pauses
/// instead of mid-word whenever possible.
enum LiveTranscriptChunker {

    /// Don't bother transcribing less than this much new audio.
    static let minChunkSeconds: TimeInterval = 4
    /// Cap each chunk so one transcription pass stays fast (a few seconds).
    static let targetChunkSeconds: TimeInterval = 12
    /// How far back from a chunk's end to look for a quiet cut point.
    static let cutSearchSeconds: TimeInterval = 1.5

    /// Frame range of the next chunk, or nil while there's not yet enough new
    /// audio past `processedFrames` to be worth a transcription pass.
    static func nextChunk(processedFrames: Int64, totalFrames: Int64,
                          sampleRate: Double) -> Range<Int64>? {
        guard sampleRate > 0 else { return nil }
        let available = totalFrames - processedFrames
        guard Double(available) / sampleRate >= minChunkSeconds else { return nil }
        let end = min(totalFrames, processedFrames + Int64(targetChunkSeconds * sampleRate))
        return processedFrames..<end
    }

    /// Given the trailing `cutSearchSeconds` of a candidate chunk, the sample
    /// offset (within `tail`) to cut at: the center of the quietest 200 ms
    /// window, so the cut lands in a pause rather than splitting a word. When
    /// the tail is too short to search, cut at its end (no refinement).
    static func refinedCutOffset(tail: [Float], sampleRate: Double) -> Int {
        let window = Int(0.2 * sampleRate)
        let hop = Int(0.05 * sampleRate)
        guard window > 0, hop > 0, tail.count > window else { return tail.count }
        var quietestStart = 0
        var quietestEnergy = Double.greatestFiniteMagnitude
        var start = 0
        while start + window <= tail.count {
            var energy = 0.0
            for i in start..<(start + window) {
                let sample = Double(tail[i])
                energy += sample * sample
            }
            if energy < quietestEnergy {
                quietestEnergy = energy
                quietestStart = start
            }
            start += hop
        }
        return quietestStart + window / 2
    }

    /// Whole-chunk silence gate: RMS below `threshold` means nothing worth
    /// sending to the ASR engine (the tee also captures the room between
    /// utterances).
    static func isSilent(_ samples: [Float], threshold: Float = 0.001) -> Bool {
        guard !samples.isEmpty else { return true }
        var sumSquares = 0.0
        for sample in samples {
            sumSquares += Double(sample) * Double(sample)
        }
        return Float(sqrt(sumSquares / Double(samples.count))) < threshold
    }
}
