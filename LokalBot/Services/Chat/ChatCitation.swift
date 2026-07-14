import Foundation

/// Inline citation markers the assistant emits — `[meeting:ID]`,
/// `[meeting:ID@HH:MM:SS]`, or `[screen:ID]` (see ChatPrompt's citation
/// instructions).
/// Messages are persisted with the markers in place; the chat UI strips them
/// for display and renders the citations as source cards that deep-link to the
/// cited meeting or exact captured screen moment.
struct ChatCitation: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case meeting
        case screen
    }

    let kind: Kind
    let sourceID: String
    /// Seconds into the meeting, when the marker carried an `@HH:MM:SS` stamp.
    let seconds: TimeInterval?

    init(meetingID: String, seconds: TimeInterval?) {
        kind = .meeting
        sourceID = meetingID
        self.seconds = seconds
    }

    init(snapshotID: Int64) {
        kind = .screen
        sourceID = String(snapshotID)
        seconds = nil
    }

    /// Backwards-compatible meeting accessor used by the existing deep-link
    /// route. Callers should check `kind == .meeting` first.
    var meetingID: String { sourceID }

    var snapshotID: Int64? {
        guard kind == .screen else { return nil }
        return Int64(sourceID)
    }

    var id: String {
        "\(kind.rawValue):\(sourceID)@\(seconds.map { String(Int($0)) } ?? "-")"
    }

    var stampText: String? {
        seconds.map { Transcript.stamp($0) }
    }
}

/// Pure marker parsing, kept out of the views so it's unit-testable.
enum ChatCitationParser {
    /// Meeting IDs match SessionLookup's short ids; screen IDs are positive
    /// SQLite row IDs. Meeting stamps accept M:SS, MM:SS, or HH:MM:SS.
    private static let pattern =
        #"\[(meeting|screen):([A-Za-z0-9_-]{1,64})(?:@(\d{1,2}(?::\d{2}){1,2}))?\]"#

    /// Split `text` into marker-free display text and the ordered, deduped
    /// citations. Text without markers passes through untouched.
    static func extract(_ text: String) -> (display: String, citations: [ChatCitation]) {
        guard text.contains("[meeting:") || text.contains("[screen:"),
              let regex = try? NSRegularExpression(pattern: pattern) else { return (text, []) }
        let ns = text as NSString
        var citations: [ChatCitation] = []
        var display = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let kind = ns.substring(with: match.range(at: 1))
            let sourceID = ns.substring(with: match.range(at: 2))
            let stamp = match.range(at: 3).location == NSNotFound
                ? nil : ns.substring(with: match.range(at: 3))
            let citation: ChatCitation?
            if kind == ChatCitation.Kind.screen.rawValue,
               stamp == nil,
               let snapshotID = Int64(sourceID), snapshotID > 0 {
                citation = ChatCitation(snapshotID: snapshotID)
            } else if kind == ChatCitation.Kind.meeting.rawValue,
                      sourceID.count >= 3 {
                citation = ChatCitation(
                    meetingID: sourceID,
                    seconds: stamp.flatMap(seconds(from:)))
            } else {
                citation = nil
            }
            guard let citation else { continue }

            display += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            if !citations.contains(citation) { citations.append(citation) }
        }
        display += ns.substring(from: cursor)
        return (cleaned(display), citations)
    }

    /// "1:23" → 83, "00:14:32" → 872. Nil for out-of-range fields.
    static func seconds(from stamp: String) -> TimeInterval? {
        let parts = stamp.split(separator: ":").map(String.init).compactMap(Int.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard parts.dropFirst().allSatisfy({ (0..<60).contains($0) }), parts[0] >= 0 else { return nil }
        let value = parts.count == 2
            ? parts[0] * 60 + parts[1]
            : parts[0] * 3600 + parts[1] * 60 + parts[2]
        return TimeInterval(value)
    }

    /// Tidy the gaps removed markers leave behind: the space before trailing
    /// punctuation and doubled interior spaces. Line-leading indentation is
    /// preserved — it's meaningful to the markdown renderer.
    private static func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]+([.,;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\S)[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
