import Foundation

// Private sidecar models. Deliberately excluded from Transcript and the CLI.
struct SpeakerTurnAnchor: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var duration: Double { max(0, end - start) }
    var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end > start }
    func overlap(_ other: Self) -> Double { max(0, min(end, other.end) - max(start, other.start)) }
}

struct SpeakerAudioTurn: Codable, Equatable, Sendable {
    var speaker: String
    var range: SpeakerTurnAnchor
}

struct ParticipantObservation: Codable, Equatable, Sendable {
    var reference: String
    var displayName: String
    var layoutEpoch: String
    var hostStart: Double
    var hostEnd: Double
    var active: Bool
    var muted: Bool = false
    var isSelf: Bool = false
    var unique: Bool = true

    static func safeName(_ raw: String) -> String? {
        let name = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...80).contains(name.count), !name.contains("@"), !name.contains("://"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !["you", "presentation", "presenting", "everyone", "shared room"].contains(name.lowercased()),
              ScreenContextPrivacy.redact(name).count == 0 else { return nil }
        return name
    }

    static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SpeakerActivityInterval: Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var participantReference: String
    var displayName: String
    var range: SpeakerTurnAnchor
    var uncertainty: Double
    var layoutEpoch: String
}

struct MeetingSpeakerEvidenceSession: Codable, Sendable {
    var schemaVersion = 1
    var meetingID: UUID
    var generation: UUID
    var provider = "google-meet-chrome-v1"
    var openedAt = Date()
    var sealed = false
    var failed = false
    var providerVerified = false
    var intervals: [SpeakerActivityInterval] = []
    var clockSpans: [AudioClockSpan] = []
}

struct MeetingSpeakerEvidenceChunk: Codable, Sendable {
    var intervals: [SpeakerActivityInterval]
    var clockSpans: [AudioClockSpan]
}

struct SpeakerNameMatch: Codable, Equatable, Identifiable, Sendable {
    enum Tier: String, Codable, Sendable { case automatic, suggested }
    enum Source: String, Codable, Sendable { case visual, profile }
    var id: String { source.rawValue + ":" + (profileID?.uuidString ?? participantReference) }
    var name: String
    var participantReference: String
    var tier: Tier
    var source: Source
    var supportSeconds: Double
    var independentTurns: Int
    var supportFraction: Double
    var contradictionSeconds: Double
    var evidence: [SpeakerTurnAnchor]
    var profileID: UUID?
    var profileRevision: Int?
    var policyVersion = "speaker-identity-1-experimental"

    var explanation: String {
        switch source {
        case .visual: "Matched meeting visuals across \(independentTurns) speaking turns"
        case .profile: "Matched a remembered voice across \(independentTurns) speaking turns"
        }
    }
}

struct SpeakerIdentityAssignment: Codable, Equatable, Identifiable, Sendable {
    enum Origin: String, Codable, Sendable {
        case visualAutomatic, profileAutomatic, calendarAutomatic, userConfirmed, userCorrected, legacy
        var isProtected: Bool { self == .userConfirmed || self == .userCorrected || self == .legacy }
    }
    var id = UUID()
    var label: String
    var name: String?
    var calendarIdentityID: String?
    var origin: Origin
    var audioRevision: String
    var anchors: [SpeakerTurnAnchor]
    var suppressedNames: [String] = []
    var automaticDisabled = false
    var match: SpeakerNameMatch?
    var supportingMatches: [SpeakerNameMatch]?
    var profileID: UUID?

    var evidencePath: String? {
        let sources = Set((supportingMatches ?? []).filter { $0.tier == .automatic }.map { $0.source.rawValue })
        if sources == ["visual", "profile"] { return "combined" }
        return match?.source.rawValue
    }
}

struct SpeakerAliasDecision: Codable, Sendable {
    enum Action: String, Codable, Sendable { case assign, dismiss, reset, undo, resume }
    var id = UUID()
    var speakerID: UUID
    var action: Action
    var sourceRevision: String
    var name: String?
    var confirmedAt = Date()
}

struct MeetingSpeakerIdentityState: Codable, Sendable {
    var schemaVersion = 1
    var meetingID: UUID
    var revision = 0
    var evidenceRevision = 0
    var audioRevision = ""
    var transcriptSignature: String?
    var timeline: [SpeakerAudioTurn] = []
    var assignments: [SpeakerIdentityAssignment] = []
    var decisions: [SpeakerAliasDecision] = []
    var suggestions: [String: [SpeakerNameMatch]] = [:]
    var analyzedAt = Date()
    var voiceSamples: [SpeakerVoiceSample] = []
    var providerVerified = false
}
