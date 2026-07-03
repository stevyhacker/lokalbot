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

    // MARK: - isSilent

    func testSilenceGate() {
        XCTAssertTrue(LiveTranscriptChunker.isSilent([Float](repeating: 0, count: 16_000)))
        XCTAssertTrue(LiveTranscriptChunker.isSilent([]))
        XCTAssertFalse(LiveTranscriptChunker.isSilent([Float](repeating: 0.1, count: 16_000)))
    }
}
