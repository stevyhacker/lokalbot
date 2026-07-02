import SwiftUI

/// Pure math behind the animated capture waveform, extracted so bar heights
/// are unit-testable without driving SwiftUI's TimelineView. Same curve as
/// the original dictation-HUD waveform.
enum LiveWaveformMath {
    /// Height of bar `index` at absolute time `time`, clamped to
    /// `minHeight...maxHeight`.
    static func height(index: Int, time: TimeInterval,
                       minHeight: CGFloat = 3, maxHeight: CGFloat = 18) -> CGFloat {
        let phase = time * 5.2
        let wave = (sin(phase + Double(index) * 0.72) + 1) / 2
        return max(minHeight,
                   min(maxHeight, minHeight + CGFloat(pow(wave, 0.7)) * (maxHeight - minHeight)))
    }
}

/// The one "audio is flowing" motion signature: tinted animated bars shared
/// by the dictation HUD, the menu-bar status card, and the recording pill.
/// Freezes at its time-zero shape under Reduce Motion.
struct LiveWaveform: View {
    var barCount: Int = 9
    var barWidth: CGFloat = 4
    var maxHeight: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(.tint)
                        .frame(width: barWidth,
                               height: LiveWaveformMath.height(
                                   index: index,
                                   time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate,
                                   maxHeight: maxHeight))
                }
            }
            .frame(height: maxHeight)
        }
    }
}
