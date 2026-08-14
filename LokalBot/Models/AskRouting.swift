import Foundation

enum AskMode: String, CaseIterable, Identifiable {
    case ask = "Ask"
    case keyword = "Keyword search"
    var id: String { rawValue }
}

enum AskSourceScope: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case meetings = "Meetings"
    case today = "Today"
    case screen = "Screen"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .meetings: "person.2"
        case .today: "sun.max"
        case .screen: "rectangle.on.rectangle"
        }
    }

    static let defaults: Set<AskSourceScope> = [.meetings, .today, .screen]
}

/// A question-scoped tool catalogue. Disabled sources are absent from the
/// agent prompt and are still denied at execution as a second boundary.
@MainActor
final class ScopedChatToolRunner: ChatToolRunner {
    private let base: ChatToolRunner
    private let scopes: Set<AskSourceScope>

    init(base: ChatToolRunner, scopes: Set<AskSourceScope>) {
        self.base = base
        self.scopes = scopes
    }

    var specs: [ChatToolSpec] { base.specs.filter { allows($0.name) } }

    func libraryOverview() -> String {
        // Today-only must not leak titles from older meetings through ambient
        // prompt context. The date-scoped tools remain available below.
        scopes.contains(.meetings) ? base.libraryOverview() : ""
    }

    func run(_ call: ChatToolCall) async -> ChatToolResult {
        guard allows(call.name) else {
            return ChatToolResult(
                text: "That local source was not enabled for this question.",
                summary: "source not enabled")
        }
        var scopedCall = call
        if scopes.contains(.today), !scopes.contains(.meetings),
           ["search_meetings", "list_meetings", "get_meeting", "get_action_items"]
            .contains(call.name) {
            var arguments = call.arguments
            arguments["_lokalbot_day_scope"] = "today"
            scopedCall = ChatToolCall(name: call.name, arguments: arguments)
        }
        if scopes.contains(.today), !scopes.contains(.screen), call.name == "search_screen" {
            var arguments = call.arguments
            arguments["_lokalbot_day_scope"] = "today"
            scopedCall = ChatToolCall(name: call.name, arguments: arguments)
        }
        if scopes.contains(.today), call.name == "activity_summary" {
            var arguments = call.arguments
            arguments["day"] = "today"
            scopedCall = ChatToolCall(name: call.name, arguments: arguments)
        }
        return await base.run(scopedCall)
    }

    private func allows(_ tool: String) -> Bool {
        switch tool {
        case "search_meetings", "list_meetings", "get_meeting", "get_action_items":
            scopes.contains(.meetings) || scopes.contains(.today)
        case "activity_summary":
            scopes.contains(.today)
        case "search_screen":
            scopes.contains(.screen) || scopes.contains(.today)
        default:
            false
        }
    }
}

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
