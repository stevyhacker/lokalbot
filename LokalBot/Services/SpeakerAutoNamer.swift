import Foundation

/// Names remote speakers from calendar attendees — but only in the one case
/// where it can't be wrong: a single remote speaker ("them") and exactly one
/// remote attendee on the matched calendar event. Multiple speakers or
/// multiple attendees are skipped entirely: diarization's first-appearance
/// order says nothing about calendar order, and a confident wrong name is
/// worse than "Them".
///
/// Names land as aliases (`Transcript.speakerAliases`), never in the raw
/// segment labels, so the rename sheet still shows, edits, and resets them
/// exactly like a manual rename.
enum SpeakerAutoNamer {

    /// The transcript with the alias applied, or the input unchanged.
    /// `participantNames` is `Meeting.participantNameHints` — already filtered
    /// upstream to remote, non-declined attendees.
    static func applyingAliases(to transcript: Transcript,
                                participantNames: [String]) -> Transcript {
        let names = participantNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard names.count == 1, let name = names.first else { return transcript }

        let remoteSpeakers = Set(transcript.segments.map {
            $0.speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }).subtracting(["me"])
        guard remoteSpeakers == ["them"] else { return transcript }

        // A previous pass or the user may have named them already — keep it.
        guard transcript.speakerAliases["them"] == nil else { return transcript }

        var named = transcript
        named.setSpeakerAlias(name, for: "them")
        return named
    }
}
