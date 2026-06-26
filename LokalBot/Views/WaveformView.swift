import SwiftUI
import AVFoundation

/// A clickable waveform scrubber for the meeting player. Peaks are computed
/// once from the audio file (downsampled so ~`bins` bars span the width),
/// cached per path so re-showing a meeting is instant. Played bars use the
/// brand teal; unplayed are muted — the same Me/Them identity the rest of the
/// app uses. Dragging scrubs; clicking seeks.
///
/// For a two-track meeting the mic track (Me) drives the shape; it's the one
/// you can rely on, and rendering both as one waveform keeps the scrubber
/// readable at small heights.
struct WaveformView: View {
    let url: URL?
    let progress: Double          // 0…1 of the track played
    let onSeek: (Double) -> Void  // progress 0…1

    @State private var peaks: [Float]?
    private let bins = 160

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if let peaks {
                    barLayer(peaks, in: geo.size, played: false)
                    barLayer(peaks, in: geo.size, played: true)
                } else {
                    // Cheap placeholder until the (off-main) analysis lands.
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary.opacity(0.4))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let p = max(0, min(1, value.location.x / max(geo.size.width, 1)))
                        onSeek(p)
                    }
            )
        }
        .frame(height: 40)
        .task(id: url?.path) { await load() }
    }

    /// Mirrored bars around the horizontal centerline — the classic waveform.
    private func barLayer(_ peaks: [Float], in size: CGSize, played: Bool) -> some View {
        let count = peaks.count
        let spacing: CGFloat = 2
        let barWidth = max(1, (size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
        let cut = Int(Double(count) * progress)
        return Canvas { ctx, _ in
            for (index, peak) in peaks.enumerated() {
                let isPlayed = index < cut
                guard played == isPlayed else { continue }
                let h = max(2, CGFloat(peak) * size.height)
                let x = CGFloat(index) * (barWidth + spacing)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                         with: .color(played ? Brand.teal : Color.secondary.opacity(0.35)))
            }
        }
    }

    /// Downsample the file to `bins` peak values, off the main actor. Uses the
    /// PCM float buffer directly — fast enough for an hour-long AAC file.
    private func load() async {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        if let cached = WaveformCache.shared.object(forKey: url.path as NSString) {
            peaks = cached.peaks
            return
        }
        let path = url.path
        let computed = await Task.detached(priority: .utility) { () -> [Float]? in
            guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: file.fileFormat.sampleRate,
                                             channels: 1) else { return nil }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
            try? file.read(into: buffer)
            guard let data = buffer.floatChannelData?[0] else { return nil }
            let total = Int(buffer.frameLength)
            let bin = max(1, total / bins)
            var out: [Float] = []
            out.reserveCapacity(bins)
            for start in stride(from: 0, to: total, by: bin) {
                let end = min(start + bin, total)
                var peak: Float = 0
                for i in start..<end { peak = max(peak, abs(data[i])) }
                out.append(peak)
            }
            // Normalize so the quietest-recorded file still fills the bar height.
            let maxPeak = out.max() ?? 1
            return maxPeak > 0 ? out.map { $0 / maxPeak } : out
        }.value
        if let computed {
            WaveformCache.shared.setObject(PeaksBox(computed), forKey: path as NSString)
            peaks = computed
        }
    }
}

/// `NSCache` requires a class; wrap the peaks array so a session can memoize
/// the (relatively) expensive audio decode per file.
private final class PeaksBox {
    let peaks: [Float]
    init(_ peaks: [Float]) { self.peaks = peaks }
}

private enum WaveformCache {
    static let shared = NSCache<NSString, PeaksBox>()
}
