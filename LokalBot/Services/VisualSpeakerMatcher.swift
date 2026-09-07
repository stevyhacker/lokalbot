import Foundation

enum VisualSpeakerMatcher {
    // These are rules, not calibrated probabilities. See the validation report.
    static let transitionGuard = 0.35

    static func matches(turns: [SpeakerAudioTurn], intervals: [SpeakerActivityInterval]) -> [String: [SpeakerNameMatch]] {
        let cleanTurns = mergedTurns(turns).filter { turn in
            turn.range.isValid && turn.speaker != "me" && !turns.contains {
                $0.speaker != turn.speaker && $0.range.overlap(turn.range) > 0.02
            }
        }
        let valid = intervals.filter {
            $0.range.isValid && $0.uncertainty.isFinite && (0...0.5).contains($0.uncertainty)
                && ParticipantObservation.safeName($0.displayName) != nil
        }
        // Conflicting/duplicate observations cannot manufacture support by repetition.
        let unambiguous = valid.filter { item in
            !valid.contains { $0.participantReference != item.participantReference && $0.range.overlap(item.range) > 0.02 }
        }
        var result: [String: [SpeakerNameMatch]] = [:]
        for (speaker, speakerTurns) in Dictionary(grouping: cleanTurns, by: \.speaker) {
            var support: [String: [SpeakerTurnAnchor]] = [:]
            var counts: [String: Int] = [:]
            var longest: [String: Double] = [:]
            for turn in speakerTurns {
                var perTurn: [String: [SpeakerTurnAnchor]] = [:]
                for item in unambiguous {
                    let guardTime = transitionGuard + item.uncertainty
                    let range = SpeakerTurnAnchor(start: max(turn.range.start + guardTime, item.range.start + item.uncertainty),
                                                  end: min(turn.range.end - guardTime, item.range.end - item.uncertainty))
                    guard range.isValid else { continue }
                    perTurn[item.participantReference, default: []].append(range)
                }
                for (reference, ranges) in perTurn {
                    let merged = union(ranges)
                    let seconds = merged.reduce(0) { $0 + $1.duration }
                    support[reference, default: []] += merged
                    if seconds >= 2 { counts[reference, default: 0] += 1 }
                    longest[reference] = max(longest[reference, default: 0], seconds)
                }
            }
            let total = support.values.flatMap { $0 }.reduce(0) { $0 + $1.duration }
            guard total > 0 else { continue }
            var candidates: [SpeakerNameMatch] = []
            for (reference, ranges) in support {
                let seconds = ranges.reduce(0) { $0 + $1.duration }
                let count = counts[reference, default: 0]
                guard seconds >= 2, count >= 1,
                      let item = unambiguous.first(where: { $0.participantReference == reference }) else { continue }
                let competingTurn = longest.contains { $0.key != reference && $0.value >= 2 }
                let automatic = seconds >= 15 && count >= 4 && seconds / total >= 0.98 && !competingTurn
                candidates.append(SpeakerNameMatch(name: item.displayName, participantReference: reference,
                    tier: automatic ? .automatic : .suggested, source: .visual, supportSeconds: seconds,
                    independentTurns: count, supportFraction: seconds / total, contradictionSeconds: total - seconds,
                    evidence: Array(ranges.prefix(8))))
            }
            result[speaker] = Array(candidates.sorted { $0.supportSeconds > $1.supportSeconds }.prefix(3))
        }
        return result
    }

    static func union(_ ranges: [SpeakerTurnAnchor]) -> [SpeakerTurnAnchor] {
        var result: [SpeakerTurnAnchor] = []
        for range in ranges.filter(\.isValid).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1].end = max(last.end, range.end)
            } else { result.append(range) }
        }
        return result
    }

    static func mergedTurns(_ turns: [SpeakerAudioTurn]) -> [SpeakerAudioTurn] {
        var result: [SpeakerAudioTurn] = []
        for turn in turns.filter({ $0.range.isValid }).sorted(by: { $0.range.start < $1.range.start }) {
            if let last = result.last, last.speaker == turn.speaker, turn.range.start - last.range.end <= 0.5 {
                result[result.count - 1].range.end = max(last.range.end, turn.range.end)
            } else { result.append(turn) }
        }
        return result
    }
}
