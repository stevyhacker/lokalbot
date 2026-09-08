import Foundation

enum OutcomeEvidencePolicy {
    static func resolve(
        speakerID: String?, basis: String?, quote: String?,
        sources: [Transcript.Segment], roster: [String: Transcript.SpeakerDescriptor]
    ) -> OutcomeAttribution {
        let unresolved = OutcomeAttribution(resolution: .unresolved, basis: .unclear)
        guard let speakerID, let person = roster[speakerID],
              person.identity != .unresolved,
              let basis = basis.flatMap(OutcomeAttribution.Basis.init(rawValue:)),
              [.commitment, .assignment, .request].contains(basis),
              let quote, !normalized(quote).isEmpty, quote.count <= 1_000 else { return unresolved }
        let quoted = sources.filter { normalized($0.displayText).contains(normalized(quote)) }
        guard !quoted.isEmpty else { return unresolved }
        if basis == .commitment {
            // This validates the speech act AFTER identity is independently
            // resolved. First-person prose alone never selects an owner.
            guard normalized(quote).range(of: #"^(i (will |shall |am going to |commit to |agree to )|i['’]ll |my next step is |ja ću |ja cu |je vais |ich werde |voy a |我会|我會)"#,
                                          options: .regularExpression) != nil else { return unresolved }
            guard quoted.allSatisfy({
                Transcript.canonicalSpeakerKey($0.speaker) == speakerID
                    && $0.resolvedAttribution.identity == person.identity
                    && $0.resolvedAttribution.method != .overlappingSpeech
            }) else { return unresolved }
        } else {
            // A request can be spoken by somebody else. Resolve its explicit
            // addressee, never assume that an isolated "you" means the user.
            let sameName = roster.values.filter { normalized($0.name) == normalized(person.name) }
            guard sameName.count == 1, !["me", "them", "local speaker", "speaker unclear"].contains(normalized(person.name)),
                  hasExplicitTarget(person.name, in: quote, basis: basis) else { return unresolved }
        }
        return OutcomeAttribution(resolution: person.identity == .user ? .user : .other,
            speakerID: speakerID, basis: basis, quote: quote)
    }

    private static func hasExplicitTarget(_ name: String, in quote: String, basis: OutcomeAttribution.Basis) -> Bool {
        let subject = NSRegularExpression.escapedPattern(for: normalized(name))
        let tail = basis == .request
            ? #"[, :]+(please\b|(?:can|could|would|will) you\b)"#
            : #"\s+(will\b|is responsible for\b|owns\b|to\b)"#
        return normalized(quote).range(of: #"(?:^|[.!?]\s*)"# + subject + tail,
            options: .regularExpression) != nil
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
