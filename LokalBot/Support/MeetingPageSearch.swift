import Foundation
import SwiftUI

/// One searchable occurrence on a meeting detail page. Locations follow the
/// page's reading order so Previous/Next can move predictably from the summary
/// into transcript evidence.
struct MeetingPageSearchMatch: Equatable {
    enum Location: Hashable {
        case notes
        case summary
        case transcript(segmentIndex: Int)

        var sectionLabel: String {
            switch self {
            case .notes: "Notes"
            case .summary: "Summary"
            case .transcript: "Transcript"
            }
        }
    }

    let location: Location
    let occurrenceIndex: Int
}

/// Pure matching logic shared by the meeting find UI and unit tests.
enum MeetingPageSearch {
    static func matches(
        query: String,
        notesText: String?,
        summaryText: String?,
        transcript: Transcript?
    ) -> [MeetingPageSearchMatch] {
        guard !normalizedQuery(query).isEmpty else { return [] }

        var result: [MeetingPageSearchMatch] = []
        appendMatches(in: notesText, at: .notes, query: query, to: &result)
        appendMatches(in: summaryText, at: .summary, query: query, to: &result)

        if let transcript {
            for (index, segment) in transcript.segments.enumerated() {
                appendMatches(
                    in: segment.displayText,
                    at: .transcript(segmentIndex: index),
                    query: query,
                    to: &result)
            }
        }
        return result
    }

    static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        let needle = normalizedQuery(query)
        guard !needle.isEmpty, !text.isEmpty else { return [] }

        var result: [Range<String.Index>] = []
        var lowerBound = text.startIndex
        while lowerBound < text.endIndex,
              let range = text.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                range: lowerBound..<text.endIndex,
                locale: .current) {
            result.append(range)
            lowerBound = range.upperBound
        }
        return result
    }

    private static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appendMatches(
        in text: String?,
        at location: MeetingPageSearchMatch.Location,
        query: String,
        to result: inout [MeetingPageSearchMatch]
    ) {
        guard let text else { return }
        for index in ranges(in: text, query: query).indices {
            result.append(.init(location: location, occurrenceIndex: index))
        }
    }
}

/// Routes the app-level Find command to the meeting detail in the focused
/// window. Other sections leave the command disabled instead of receiving a
/// global notification intended for a different window.
struct MeetingPageSearchAction {
    let perform: () -> Void

    func callAsFunction() {
        perform()
    }
}

private struct MeetingPageSearchActionKey: FocusedValueKey {
    typealias Value = MeetingPageSearchAction
}

extension FocusedValues {
    var meetingPageSearchAction: MeetingPageSearchAction? {
        get { self[MeetingPageSearchActionKey.self] }
        set { self[MeetingPageSearchActionKey.self] = newValue }
    }
}
