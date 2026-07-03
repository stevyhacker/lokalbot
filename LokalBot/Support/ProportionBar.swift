import SwiftUI

/// Math behind the per-app proportion bar, separated from the view for unit
/// tests (same pattern as `LiveWaveformMath`).
enum ProportionBarMath {
    struct Segment: Equatable {
        let label: String
        let fraction: Double
    }

    /// Per-app seconds → ordered fractions of the whole, folding everything
    /// past `cap` apps into an "Other" segment. Zero totals produce an empty
    /// bar rather than NaN fractions.
    static func segments(perApp: [(label: String, seconds: TimeInterval)],
                         cap: Int = 6) -> [Segment] {
        let positive = perApp.filter { $0.seconds > 0 }
        let total = positive.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return [] }
        let sorted = positive.sorted { $0.seconds > $1.seconds }
        let top = sorted.prefix(cap).map {
            Segment(label: $0.label, fraction: $0.seconds / total)
        }
        let rest = sorted.dropFirst(cap).reduce(0) { $0 + $1.seconds }
        guard rest > 0 else { return top }
        return top + [Segment(label: "Other", fraction: rest / total)]
    }
}

/// Horizontal stacked proportion bar (spec §3.2): one rounded track whose
/// segments show each app's share of the tracked day. Colors come from the
/// caller so the bar stays in the same family as the hour track.
struct ProportionBar: View {
    let segments: [(segment: ProportionBarMath.Segment, color: Color)]
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { pair in
                    Rectangle()
                        .fill(pair.element.color)
                        .frame(width: max(1, geo.size.width * pair.element.segment.fraction))
                }
            }
        }
        .frame(height: height)
        .background(.quaternary.opacity(0.4))
        .clipShape(Capsule())
    }
}
