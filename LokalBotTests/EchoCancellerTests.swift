import XCTest
@testable import LokalBot

/// The echo canceller learns the path from the Mac's speakers back into its
/// microphone and subtracts it, so the user's own voice is what is left.
/// Synthetic room here — a delay plus a decaying tail — because a real room's
/// impulse response is exactly what the filter is supposed to discover.
final class EchoCancellerTests: XCTestCase {

    private let sampleRate = SpanAudioReader.sampleRate

    /// Deterministic noise: `Float.random` would make a convergence assertion
    /// flaky for no benefit. Zero-mean matters — a shared DC offset is a real
    /// component the canceller would correctly subtract, which looks exactly
    /// like it eating the user's voice.
    private func noise(_ count: Int, seed: UInt64 = 42) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24)      // [0, 1)
            return unit * 2 - 1
        }
    }

    /// Speaker → room → microphone: a delay and a short decaying tail.
    private func echo(of reference: [Float], delay: Int, gain: Float = 0.5) -> [Float] {
        var out = [Float](repeating: 0, count: reference.count)
        let tail: [Float] = [gain, gain * 0.4, gain * 0.15, gain * 0.05]
        for (offset, weight) in tail.enumerated() {
            let shift = delay + offset * 17
            for n in shift..<reference.count {
                out[n] += weight * reference[n - shift]
            }
        }
        return out
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    func testCancelsAKnownEchoPath() {
        let reference = noise(Int(sampleRate) * 8)
        let microphone = echo(of: reference, delay: 120)
        var canceller = EchoCanceller()

        let residual = canceller.process(microphone: microphone, reference: reference)

        // Judge the converged tail, not the first pass over an unknown room.
        let tail = Int(sampleRate) * 6
        XCTAssertLessThan(rms(Array(residual[tail...])), rms(Array(microphone[tail...])) * 0.1)
        XCTAssertGreaterThan(canceller.echoReturnLossDB, 10)
    }

    /// Headphones: nothing of the remote audio is in the microphone, and the
    /// filter must leave the user's voice alone rather than fit noise.
    func testLeavesTheMicrophoneAloneWhenThereIsNoEcho() {
        let reference = noise(Int(sampleRate) * 8, seed: 7)
        let voice = noise(Int(sampleRate) * 8, seed: 99).map { $0 * 0.3 }
        var canceller = EchoCanceller()

        let residual = canceller.process(microphone: voice, reference: reference)

        XCTAssertEqual(rms(residual), rms(voice), accuracy: rms(voice) * 0.1)
        XCTAssertLessThan(canceller.echoReturnLossDB, 1)
    }

    /// The user talking over the remote side. Without a double-talk guard the
    /// filter learns to cancel *them*, which is worse than no cancellation —
    /// a first attempt diverged to -17 dB exactly here.
    func testKeepsTheUsersVoiceThroughDoubleTalk() {
        let reference = noise(Int(sampleRate) * 10)
        var microphone = echo(of: reference, delay: 120)
        let voice = noise(Int(sampleRate) * 10, seed: 5).map { $0 * 0.6 }
        let talkStart = Int(sampleRate) * 6
        for n in talkStart..<microphone.count { microphone[n] += voice[n] }
        var canceller = EchoCanceller()

        let residual = canceller.process(microphone: microphone, reference: reference)

        // The user's own words survive at close to their original level.
        let spoken = Array(residual[talkStart...])
        XCTAssertEqual(rms(spoken), rms(Array(voice[talkStart...])), accuracy: rms(voice) * 0.35)
        XCTAssertGreaterThan(canceller.echoReturnLossDB, 3)
    }

    func testFindsTheBulkDelay() {
        let reference = noise(Int(sampleRate) * 6)
        let microphone = echo(of: reference, delay: Int(0.146 * sampleRate))

        let delay = EchoDelayEstimator.delay(microphone: microphone, reference: reference,
                                             sampleRate: sampleRate)

        // Envelope resolution is one 10 ms frame, deliberately biased early so
        // the causal filter can still reach the echo.
        XCTAssertGreaterThan(delay, Int(0.10 * sampleRate))
        XCTAssertLessThanOrEqual(delay, Int(0.146 * sampleRate))
    }

    /// Runs the whole stage over a real meeting folder when one is pointed at,
    /// so the numbers in the log come from actual audio rather than a model of
    /// it. Skips by default — no fixture, no network, no fixed path.
    func testRealMeetingFolderIfProvided() throws {
        guard let folder = ProcessInfo.processInfo.environment["LOKALBOT_AEC_FIXTURE"] else {
            throw XCTSkip("set LOKALBOT_AEC_FIXTURE to a meeting folder to run this")
        }
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        // Keep the result when a path is given, so the cleaned track can be
        // measured against the original instead of only being scored by the
        // filter's own ERLE.
        let keep = ProcessInfo.processInfo.environment["LOKALBOT_AEC_OUTPUT"]
        let destination = keep.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("aec-\(UUID().uuidString).wav")
        defer { if keep == nil { try? FileManager.default.removeItem(at: destination) } }

        let report = try EchoCancelledTrack.write(
            microphone: root.appendingPathComponent("mic.m4a"),
            reference: root.appendingPathComponent("system.m4a"),
            to: destination)

        print("AEC report: delay=\(report.delaySeconds * 1000) ms "
                + "erle=\(report.echoReturnLossDB) dB "
                + "processed=\(report.processedSeconds) s")
        XCTAssertGreaterThan(report.processedSeconds, 1)
    }
}
