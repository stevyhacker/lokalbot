import Foundation

enum OutcomeEvidencePolicy {
    static func resolve(
        speakerID: String?, basis: String?, quote: String?,
        sources: [Transcript.Segment], roster: [String: Transcript.SpeakerDescriptor]
    ) -> OutcomeAttribution {
        func reject(_ reason: OutcomeAttribution.RejectionReason) -> OutcomeAttribution {
            OutcomeAttribution(resolution: .unresolved, speakerID: speakerID.flatMap { roster[$0] == nil ? nil : $0 },
                               basis: .unclear, rejectionReason: reason)
        }
        guard let speakerID else { return reject(.missingSpeaker) }
        guard let person = roster[speakerID] else { return reject(.unknownSpeaker) }
        guard person.identity != .unresolved else { return reject(.unconfirmedIdentity) }
        guard let basis = basis.flatMap(OutcomeAttribution.Basis.init(rawValue:)),
              [.commitment, .assignment, .request].contains(basis) else { return reject(.missingBasis) }
        guard let quote, !normalized(quote).isEmpty, quote.count <= 1_000 else { return reject(.missingQuote) }
        let quoted = sources.filter { normalized($0.displayText).contains(normalized(quote)) }
        guard !quoted.isEmpty else { return reject(.quoteNotFound) }
        if basis == .commitment {
            // Identity comes from the cited voice. Conversational acceptance is
            // evidence of a commitment, never evidence that the speaker is "Me".
            guard isCommitment(quote), quoted.allSatisfy({ supportsCommitment(quote, in: $0.displayText) }) else {
                return reject(.unsupportedCommitment)
            }
            guard quoted.allSatisfy({
                Transcript.canonicalSpeakerKey($0.speaker) == speakerID
                    && $0.resolvedAttribution.identity == person.identity
                    && ![.overlappingSpeech, .suspectedEcho].contains($0.resolvedAttribution.method)
            }) else { return reject(.speakerMismatch) }
        } else {
            let names = uniqueTargetNames(for: person, roster: roster)
            guard !names.isEmpty else { return reject(.ambiguousName) }
            guard names.contains(where: { name in
                hasExplicitTarget(name, in: quote, basis: basis) && quoted.allSatisfy { source in
                    evidenceClause(quote, in: source.displayText).map { hasExplicitTarget(name, in: $0, basis: basis) } == true
                }
            }) else {
                return reject(.targetNotExplicit)
            }
        }
        return OutcomeAttribution(resolution: person.identity == .user ? .user : .other,
            speakerID: speakerID, basis: basis, quote: quote)
    }

    /// Allow discourse markers and explicit acceptance, but not capability
    /// questions, hypothetical promises, past reports, or collective "we".
    static func isCommitment(_ raw: String) -> Bool {
        let text = normalized(raw)
        let start = #"^(?:(?:yes|yeah|yep|okay|ok|sure|right|well|so|and|then|absolutely)[,!.: ]+)*"#
        let undertaking = #"(?:i (?:will|shall|am going to|commit to|agree to)|i['’]ll|my next step is)\s+(?!not\b|never\b|no longer\b)\S"#
        let acceptance = #"i can (?:do (?:that|it)|take (?:that|it)(?: on)?|handle (?:that|it))\b"#
        let translated = #"(?:ja ću |ja cu |je vais |ich werde |voy a |我会|我會)"#
        guard text.range(of: start + "(?:" + undertaking + "|" + acceptance + "|" + translated + ")",
                         options: .regularExpression) != nil else { return false }
        // Preserve surrounding uncertainty even when a short quote omits it.
        return text.range(of: #"\?|\b(?:if|unless|might|maybe|perhaps|cannot|can't|can’t|won't|won’t)\b"#,
                          options: .regularExpression) == nil
    }

    private static func supportsCommitment(_ quote: String, in source: String) -> Bool {
        evidenceClause(quote, in: source).map(isCommitment) == true
    }

    private static func evidenceClause(_ quote: String, in source: String) -> String? {
        let text = normalized(source)
        guard let match = text.range(of: normalized(quote)) else { return nil }
        let prefix = text[..<match.lowerBound]
        let boundary = prefix.lastIndex(where: { ".!?;".contains($0) })
        let start = boundary.map { text.index(after: $0) } ?? text.startIndex
        let suffix = text[match.upperBound...]
        let quoteEndsClause = ".!?;".contains(text[text.index(before: match.upperBound)])
        let end = quoteEndsClause ? match.upperBound
            : suffix.firstIndex(where: { ".!?;".contains($0) }).map { text.index(after: $0) } ?? text.endIndex
        return String(text[start..<end])
    }

    private static func uniqueTargetNames(for person: Transcript.SpeakerDescriptor,
                                          roster: [String: Transcript.SpeakerDescriptor]) -> [String] {
        let name = normalized(person.name)
        guard !["me", "you", "them", "local speaker", "speaker unclear"].contains(name),
              name.range(of: #"^(?:them|local|speaker)(?:\s+\d+|\s+unclear)?$"#, options: .regularExpression) == nil else { return [] }
        // First names are usable only when they identify one named speaker.
        let candidates = [name, name.split(separator: " ").first.map(String.init)].compactMap { $0 }
        return Array(Set(candidates)).filter { candidate in
            roster.values.filter { other in
                let otherName = normalized(other.name)
                return otherName == candidate || otherName.split(separator: " ").first.map(String.init) == candidate
            }.count == 1
        }
    }

    private static func hasExplicitTarget(_ name: String, in quote: String, basis: OutcomeAttribution.Basis) -> Bool {
        let subject = NSRegularExpression.escapedPattern(for: name)
        let text = normalized(quote)
        guard text.range(of: #"\b(?:if|unless|might|maybe|perhaps)\b"#, options: .regularExpression) == nil else { return false }
        let start = #"(?:^|[.!?]\s*)(?:(?:okay|ok|so|and|then|yes|yeah)[, ]+)*"#
        let patterns: [String]
        if basis == .request {
            patterns = [
                start + subject + #"[, :]+(?:please\b|(?:can|could|would|will) you\b)"#,
                start + #"(?:can|could|would|will) you,\s*"# + subject + #"[, :]"#,
                start + #"(?:please|can|could|would|will)\s+"# + subject + #"\s+(?!not\b)\w"#,
            ]
        } else {
            patterns = [start + subject + #"\s+(?:will\s+(?!not\b)|is responsible for\s+|owns\s+|to\s+)\w"#]
        }
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
