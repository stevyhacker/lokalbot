import XCTest
@testable import LokalBot

final class LiveTranscriptChunkerTests: XCTestCase {

    private let rate = 16_000.0

    // MARK: - nextChunk

    func testNoChunkUntilMinimumAudioAvailable() {
        let justUnder = Int64(LiveTranscriptChunker.minChunkSeconds * rate) - 1
        XCTAssertNil(LiveTranscriptChunker.nextChunk(
            processedFrames: 0, totalFrames: justUnder, sampleRate: rate))
    }

    func testChunkAtExactMinimumBoundary() {
        let exactly = Int64(LiveTranscriptChunker.minChunkSeconds * rate)
        let chunk = LiveTranscriptChunker.nextChunk(
            processedFrames: 0, totalFrames: exactly, sampleRate: rate)
        XCTAssertEqual(chunk, 0..<exactly)
    }

    func testChunkCappedAtTargetWhenBacklogIsLarge() {
        let total = Int64(60 * rate)
        let chunk = LiveTranscriptChunker.nextChunk(
            processedFrames: 0, totalFrames: total, sampleRate: rate)
        XCTAssertEqual(chunk, 0..<Int64(LiveTranscriptChunker.targetChunkSeconds * rate))
    }

    func testChunkStartsAtProcessedFrames() {
        let processed = Int64(10 * rate)
        let total = Int64(16 * rate)
        let chunk = LiveTranscriptChunker.nextChunk(
            processedFrames: processed, totalFrames: total, sampleRate: rate)
        XCTAssertEqual(chunk, processed..<total)
    }

    func testZeroSampleRateProducesNoChunk() {
        XCTAssertNil(LiveTranscriptChunker.nextChunk(
            processedFrames: 0, totalFrames: 1_000_000, sampleRate: 0))
    }

    // MARK: - refinedCutOffset

    func testCutLandsInTheQuietValley() {
        // 1.5 s of loud signal with a silent stretch at a known position.
        var tail = [Float](repeating: 0.5, count: Int(LiveTranscriptChunker.cutSearchSeconds * rate))
        let valleyStart = 8_000
        let window = Int(0.2 * rate)
        for i in valleyStart..<(valleyStart + window) { tail[i] = 0 }
        let cut = LiveTranscriptChunker.refinedCutOffset(tail: tail, sampleRate: rate)
        XCTAssertEqual(cut, valleyStart + window / 2)
    }

    func testShortTailCutsAtItsEnd() {
        let tail = [Float](repeating: 0.5, count: 1_000) // shorter than the 200 ms window
        XCTAssertEqual(LiveTranscriptChunker.refinedCutOffset(tail: tail, sampleRate: rate), 1_000)
    }

    func testUniformTailStillReturnsAValidOffset() {
        let tail = [Float](repeating: 0.3, count: Int(rate))
        let cut = LiveTranscriptChunker.refinedCutOffset(tail: tail, sampleRate: rate)
        XCTAssertGreaterThan(cut, 0)
        XCTAssertLessThanOrEqual(cut, tail.count)
    }

    // MARK: - hasSpeech

    func testPureSilenceHasNoSpeech() {
        // A dead input (several seconds of digital zeros) must never reach the ASR.
        XCTAssertFalse(LiveTranscriptChunker.hasSpeech(
            [Float](repeating: 0, count: Int(4 * rate)), sampleRate: rate))
    }

    func testStationaryRoomToneHasNoSpeech() {
        // THE regression case: a muted participant's mic feeds hot room tone
        // (RMS ≈ 0.014, far above the old 0.001 whole-chunk threshold) that
        // Whisper hallucinated "Me" lines from.
        XCTAssertFalse(LiveTranscriptChunker.hasSpeech(
            tone(amplitude: 0.02, seconds: 4), sampleRate: rate))
    }

    func testLoudStationaryHumHasNoSpeech() {
        // No dynamics means no speech, no matter how loud the hum is.
        XCTAssertFalse(LiveTranscriptChunker.hasSpeech(
            tone(amplitude: 0.25, seconds: 4), sampleRate: rate))
    }

    func testSpeechLikeBurstsOverQuietFloorHaveSpeech() {
        // Syllable-like bursts over a quiet floor, 0.9 s total: clearly speech.
        var samples = tone(amplitude: 0.002, seconds: 6)
        for second in [1.0, 3.0, 5.0] {
            burst(into: &samples, at: second, seconds: 0.3, amplitude: 0.1)
        }
        XCTAssertTrue(LiveTranscriptChunker.hasSpeech(samples, sampleRate: rate))
    }

    func testQuietBurstsJustAboveAbsoluteFloorHaveSpeech() {
        // Very quiet speech (burst RMS ≈ 0.014, ~4.7× the absolute floor) over
        // a near-silent room must still pass the gate.
        var samples = tone(amplitude: 0.0005, seconds: 6)
        for second in [1.0, 3.0, 5.0] {
            burst(into: &samples, at: second, seconds: 0.3, amplitude: 0.02)
        }
        XCTAssertTrue(LiveTranscriptChunker.hasSpeech(samples, sampleRate: rate))
    }

    func testSpeechOverHotRoomToneHasSpeech() {
        // Dynamics rescue what an absolute threshold would misjudge: the same
        // hot room tone as the regression case, plus real speech bursts.
        var samples = tone(amplitude: 0.02, seconds: 6)
        for second in [1.0, 3.0, 5.0] {
            burst(into: &samples, at: second, seconds: 0.3, amplitude: 0.2)
        }
        XCTAssertTrue(LiveTranscriptChunker.hasSpeech(samples, sampleRate: rate))
    }

    func testSingleShortBurstIsBelowMinimumActiveTime() {
        // One hop-aligned 0.2 s burst activates only 0.3 s of windows — under
        // the 0.4 s minimum — so a stray thump or click doesn't trigger the ASR.
        var samples = tone(amplitude: 0.002, seconds: 6)
        burst(into: &samples, at: 3.0, seconds: 0.2, amplitude: 0.1)
        XCTAssertFalse(LiveTranscriptChunker.hasSpeech(samples, sampleRate: rate))
    }

    func testEmptyChunkHasNoSpeech() {
        XCTAssertFalse(LiveTranscriptChunker.hasSpeech([], sampleRate: rate))
    }

    func testZeroSampleRateHasNoSpeech() {
        XCTAssertFalse(LiveTranscriptChunker.hasSpeech(
            [Float](repeating: 0.1, count: 16_000), sampleRate: 0))
    }

    func testSubWindowChunkAboveAbsoluteFloorHasSpeech() {
        // Shorter than one 200 ms window: falls back to whole-chunk RMS.
        XCTAssertTrue(LiveTranscriptChunker.hasSpeech(
            tone(amplitude: 0.1, seconds: 0.1), sampleRate: rate))
    }

    func testSubWindowChunkBelowAbsoluteFloorHasNoSpeech() {
        // Shorter than one window and below the absolute floor: not speech.
        XCTAssertFalse(LiveTranscriptChunker.hasSpeech(
            tone(amplitude: 0.002, seconds: 0.1), sampleRate: rate))
    }

    // MARK: - Synthesis helpers

    /// 400 Hz sine: its 40-sample period at 16 kHz divides the gate's window
    /// and hop exactly, so every full window has RMS = amplitude/√2 and every
    /// test is fully deterministic.
    private func tone(amplitude: Float, seconds: Double) -> [Float] {
        (0..<Int((seconds * rate).rounded())).map {
            amplitude * Float(sin(2 * Double.pi * 400 * Double($0) / rate))
        }
    }

    /// Overwrite a hop-aligned stretch of `samples` with a louder 400 Hz
    /// burst, standing in for a run of syllables.
    private func burst(into samples: inout [Float], at second: Double,
                       seconds: Double, amplitude: Float) {
        let start = Int((second * rate).rounded())
        for i in 0..<Int((seconds * rate).rounded()) {
            samples[start + i] = amplitude * Float(sin(2 * Double.pi * 400 * Double(i) / rate))
        }
    }
}
