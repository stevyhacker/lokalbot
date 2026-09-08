import Foundation

/// A narrow fallback for near-identical digital echoes. Normal room echoes
/// are handled by AEC; lexical similarity cannot authorize deleting speech.
enum EchoWaveformEvidence {
    static func verified(in transcript: Transcript, folder: URL) async throws -> Set<Int> {
        let indices = SpeakerBleedFilter.filter(transcript).suspectedIndices.sorted().prefix(100)
        guard !indices.isEmpty else { return [] }
        let worker = Task.detached(priority: .utility) { () -> Set<Int> in
            guard let micURL = MeetingAudioFiles.transcribableURL(for: .mic, in: folder),
                  let remoteURL = MeetingAudioFiles.transcribableURL(for: .system, in: folder) else { return [] }
            let timing = (try? Data(contentsOf: folder.appendingPathComponent(RecordingAudioTiming.fileName)))
                .flatMap { try? JSONDecoder().decode(RecordingAudioTiming.self, from: $0) }
            var verified = Set<Int>()
            for index in indices {
                try Task.checkCancellation()
                let segment = transcript.segments[index]
                let mapped = timing?.referenceRange(start: segment.start, end: segment.end)
                if timing != nil && mapped == nil { continue }
                let referenceRange = mapped ?? SpeakerTurnAnchor(start: segment.start, end: segment.end)
                guard let microphone = try? SpanAudioReader(url: micURL).samples(from: segment.start, to: segment.end),
                      let reference = try? SpanAudioReader(url: remoteURL).samples(from: referenceRange.start, to: referenceRange.end),
                      nearIdentical(microphone: microphone, reference: reference) else { continue }
                verified.insert(index)
            }
            return verified
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func nearIdentical(microphone: [Float], reference: [Float]) -> Bool {
        guard microphone.count >= 16_000, abs(microphone.count - reference.count) <= 32 else { return false }
        let estimate = EchoDelayEstimator.estimate(microphone: microphone, reference: reference, sampleRate: 16_000)
        guard estimate.isReliable else { return false }
        // Decimated waveform comparison keeps the bounded fallback inexpensive.
        // The threshold deliberately accepts only near-exact copies, not two
        // people speaking the same words, or a mixture containing a quiet reply.
        let mic = stride(from: 0, to: microphone.count, by: 16).map { Double(microphone[$0]) }
        let remote = stride(from: 0, to: reference.count, by: 16).map { Double(reference[$0]) }
        let center = estimate.samples / 16
        return (center - 20...center + 20).contains { shift in
            EchoDelayEstimator.correlation(mic, remote, shift: shift) >= 0.999
        }
    }
}
