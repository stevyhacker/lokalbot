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

    // MARK: - Speech gate

    /// Windowing for the speech gate: RMS is measured over 200 ms windows
    /// hopped every 100 ms, so each active window accounts for ~100 ms of
    /// speech time.
    static let gateWindowSeconds = 0.2
    static let gateHopSeconds = 0.1
    /// Ignore anything below ≈ −50 dBFS outright — even hot input gain puts
    /// real speech well above this.
    static let gateAbsoluteFloor: Float = 0.003
    /// An active window must rise ≥ 10 dB (≈ 3.16×) above the chunk's noise
    /// floor. Speech is bursty — syllables swing far above the pauses between
    /// them — while room tone, fans, and hum are stationary and never clear
    /// this margin no matter how loud they are.
    static let gateActiveMargin: Float = 3.16
    /// Total active time required before a chunk is worth an ASR pass.
    static let gateMinActiveSeconds = 0.4

    /// Whether a candidate chunk contains speech-like audio worth sending to
    /// the ASR engine. A call app's "mute" only stops the app transmitting —
    /// the physical mic keeps feeding our tee, so a muted participant's track
    /// is room tone, keyboard, and fan noise. Whisper-family models
    /// hallucinate fluent sentences on exactly that kind of non-speech audio
    /// (in random languages when auto-detecting), which surfaced as "Me"
    /// lines the user never said. A single whole-chunk RMS threshold can't
    /// separate hot room tone from quiet speech, so this gate keys on
    /// dynamics instead: the noise floor is a low-percentile window RMS, and
    /// the chunk passes only when enough total time rises both `gateActiveMargin`
    /// above that floor and above `gateAbsoluteFloor`.
    static func hasSpeech(_ samples: [Float], sampleRate: Double) -> Bool {
        guard sampleRate > 0, !samples.isEmpty else { return false }
        let window = Int(gateWindowSeconds * sampleRate)
        let hop = Int(gateHopSeconds * sampleRate)
        guard window > 0, hop > 0 else { return false }

        // Chunk shorter than one window: fall back to a plain RMS check.
        guard samples.count >= window else {
            return rms(samples, 0, samples.count) > gateAbsoluteFloor
        }

        var windowRMS: [Float] = []
        windowRMS.reserveCapacity(samples.count / hop + 1)
        var start = 0
        while start + window <= samples.count {
            windowRMS.append(rms(samples, start, window))
            start += hop
        }

        // Noise floor: the 20th-percentile window — quiet parts of the chunk.
        let sorted = windowRMS.sorted()
        let floor = sorted[sorted.count / 5]
        let threshold = max(gateAbsoluteFloor, floor * gateActiveMargin)

        let activeSeconds = Double(windowRMS.count(where: { $0 > threshold })) * gateHopSeconds
        return activeSeconds >= gateMinActiveSeconds
    }

    private static func rms(_ samples: [Float], _ start: Int, _ count: Int) -> Float {
        var sumSquares = 0.0
        for i in start..<(start + count) {
            let sample = Double(samples[i])
            sumSquares += sample * sample
        }
        return Float(sqrt(sumSquares / Double(count)))
    }
}
