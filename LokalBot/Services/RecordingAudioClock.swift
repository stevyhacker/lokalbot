import AudioToolbox
import Foundation

struct AudioClockSpan: Codable, Equatable, Sendable {
    var hostStart: Double
    var hostEnd: Double
    var startFrame: Int64
    var endFrame: Int64
    var sampleRate: Double
    var generation: Int
}

/// Receives anchors on the audio writer queue, only AFTER successful writes.
/// No locks, allocations, conversion or I/O are added to the real-time callback.
final class RecordingAudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var spans: [AudioClockSpan] = []
    private var generation = 0
    private var invalidated = false
    private var fileSampleRate: Double?
    static func hostSeconds(_ ticks: UInt64) -> Double {
        Double(AudioConvertHostTimeToNanos(ticks)) / 1_000_000_000
    }
    static var now: Double { hostSeconds(AudioGetCurrentHostTime()) }

    func record(hostTime: UInt64, valid: Bool, startFrame: Int64, frames: Int64, sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated, valid, frames > 0, sampleRate.isFinite, sampleRate > 0 else {
            generation += 1
            return
        }
        let start = Self.hostSeconds(hostTime)
        let end = start + Double(frames) / sampleRate
        guard start.isFinite, end > start else { generation += 1; return }
        if let fileSampleRate, fileSampleRate != sampleRate {
            // The recorder rejects incompatible reattachments. If a caller
            // nevertheless supplies one, never reinterpret old file frames.
            generation += 1
            return
        }
        fileSampleRate = sampleRate
        if let last = spans.last, start < last.hostEnd - 0.002 {
            spans.removeAll(keepingCapacity: true)
            generation += 1
            return
        }
        if let last = spans.last, last.generation == generation,
           last.sampleRate == sampleRate, last.endFrame == startFrame,
           abs(last.hostEnd - start) <= 0.002,
           abs(last.hostStart + Double(startFrame - last.startFrame) / sampleRate - start) <= 0.005 {
            spans[spans.count - 1].hostEnd = end
            spans[spans.count - 1].endFrame = startFrame + frames
        } else {
            generation += 1
            // A small rolling map is sufficient: observations are mapped immediately.
            if spans.count >= 512 { spans.removeFirst(128) }
            spans.append(AudioClockSpan(hostStart: start, hostEnd: end, startFrame: startFrame,
                                        endFrame: startFrame + frames, sampleRate: sampleRate, generation: generation))
        }
    }

    func discontinuity() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    func snapshot() -> [AudioClockSpan] {
        lock.lock()
        defer { lock.unlock() }
        return Array(spans.suffix(64))
    }

    /// Both bounds must lie within a single contiguous span. Never extrapolate.
    func map(hostStart: Double, hostEnd: Double) -> SpeakerTurnAnchor? {
        lock.lock()
        defer { lock.unlock() }
        guard hostStart.isFinite, hostEnd.isFinite, hostEnd > hostStart,
              let span = spans.last(where: { $0.hostStart <= hostStart && $0.hostEnd >= hostEnd }) else { return nil }
        return SpeakerTurnAnchor(start: Double(span.startFrame) / span.sampleRate + hostStart - span.hostStart,
                                 end: Double(span.startFrame) / span.sampleRate + hostEnd - span.hostStart)
    }
}
