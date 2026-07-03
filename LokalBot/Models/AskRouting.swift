import Foundation

/// Which mode the Ask surface shows (spec §2.3 "one input, two response
/// modes"). Typing always means live search; an empty query falls back to
/// the active conversation, or the suggestion empty state when there is none.
enum AskPhase: Equatable {
    case idle, searching, conversation
}

enum AskRouter {
    static func phase(query: String, hasMessages: Bool) -> AskPhase {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .searching
        }
        return hasMessages ? .conversation : .idle
    }
}

/// Kind facet chips over the unified Ask result list — replaces the old
/// Search scope segmented control and its separate Screen mode.
enum AskFacet: String, CaseIterable, Identifiable {
    case all = "All"
    case transcripts = "Transcripts"
    case summaries = "Summaries"
    case screen = "Screen"

    var id: String { rawValue }

    /// The FTS index kind this facet narrows to; `nil` for All (no filter)
    /// and Screen (which queries the OCR store instead of the FTS index).
    var kind: SearchIndex.Kind? {
        switch self {
        case .all, .screen: nil
        case .transcripts: .segment
        case .summaries: .summary
        }
    }
}
