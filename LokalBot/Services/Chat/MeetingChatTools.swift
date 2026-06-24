import Foundation

/// Renders tool output for the chat model. Pure value-in / string-out so the
/// formatting is unit-testable without the file system, indexes, or an engine.
/// Kept compact on purpose — observations are fed back into a small local model.
enum MeetingChatFormat {

    /// Ambient context folded into the system prompt: how many meetings exist and
    /// the most recent few, so list-style questions need no tool call.
    static func libraryOverview(_ meetings: [Meeting], limit: Int) -> String {
        guard !meetings.isEmpty else { return "The user has no recorded meetings yet." }
        let count = meetings.count
        var lines = ["The user has \(count) recorded meeting\(count == 1 ? "" : "s"). Most recent:"]
        for meeting in meetings.prefix(limit) {
            lines.append("- [\(SessionLookup.shortID(meeting.id))] \(meeting.title) — "
                + "\(dateLabel(meeting.startedAt)), \(meeting.durationLabel)")
        }
        if count > limit { lines.append("- … and \(count - limit) older.") }
        return lines.joined(separator: "\n")
    }

    static func list(_ meetings: [Meeting]) -> String {
        guard !meetings.isEmpty else { return "No meetings match." }
        return meetings.map { meeting in
            "- [\(SessionLookup.shortID(meeting.id))] \(meeting.title) — "
                + "\(dateLabel(meeting.startedAt)), \(meeting.durationLabel), \(meeting.appName)"
        }.joined(separator: "\n")
    }

    static func searchResults(query: String,
                              keyword: [SearchIndex.Hit],
                              semantic: [EmbeddingIndex.Hit],
                              meetings: [Meeting]) -> String {
        guard !keyword.isEmpty || !semantic.isEmpty else { return "No matches for “\(query)”." }
        let byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func title(_ id: UUID) -> String { byID[id]?.title ?? "Unknown meeting" }

        var lines: [String] = []
        if !keyword.isEmpty {
            lines.append("Keyword matches:")
            for hit in keyword.prefix(8) {
                let stamp = hit.kind == .segment ? " @ \(Transcript.stamp(hit.start))" : ""
                let who = hit.speaker.isEmpty ? "" : " (\(hit.speaker.capitalized))"
                lines.append("- [\(SessionLookup.shortID(hit.meetingID))] \(title(hit.meetingID))"
                    + "\(stamp) [\(hit.kind.rawValue)]\(who): \(clean(hit.snippet))")
            }
        }
        if !semantic.isEmpty {
            lines.append("Related (semantic) matches:")
            for hit in semantic.prefix(5) {
                let stamp = hit.start > 0 ? " @ \(Transcript.stamp(hit.start))" : ""
                lines.append("- [\(SessionLookup.shortID(hit.meetingID))] \(title(hit.meetingID))"
                    + "\(stamp): \(clean(hit.text))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func meeting(_ meeting: Meeting, summary: String?, transcript: String?,
                        include: String) -> String {
        let want = include.lowercased()
        let all = want.contains("all")
        var lines = [
            "# \(meeting.title)",
            "Date: \(dateLabel(meeting.startedAt)) · Duration: \(meeting.durationLabel)"
                + " · App: \(meeting.appName) · ID: \(SessionLookup.shortID(meeting.id))",
        ]
        if all || want.contains("summary") || (!want.contains("transcript")) {
            lines.append("")
            lines.append("## Summary")
            lines.append(summary?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "No summary available for this meeting yet.")
        }
        if all || want.contains("transcript") {
            lines.append("")
            lines.append("## Transcript")
            if let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(capped(transcript, max: 6000))
            } else {
                lines.append("No transcript available for this meeting yet.")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Strip FTS5 «»-markers, collapse whitespace, and cap a single snippet.
    static func clean(_ snippet: String) -> String {
        let collapsed = snippet
            .replacingOccurrences(of: "«", with: "")
            .replacingOccurrences(of: "»", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 220 ? String(collapsed.prefix(220)) + "…" : collapsed
    }

    static func capped(_ text: String, max: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        return String(trimmed.prefix(max)) + "\n…(truncated)"
    }

    static func dateLabel(_ date: Date) -> String { formatter.string(from: date) }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// The chat tool surface: natural-language search, listing, and reading meetings.
/// Backed by the app's live state — the loaded meeting list, the FTS5 keyword
/// index, the semantic embedding index, and on-disk artifacts — so the chat
/// reflects exactly what the rest of the app sees (and honours the UI-test
/// storage-root override, unlike the CLI's hard-coded `SessionLookup` paths).
@MainActor
final class MeetingChatTools: ChatToolRunner {
    private let meetingsProvider: () -> [Meeting]
    private let storage: StorageManager
    private let searchIndex: SearchIndex
    private let embeddingIndex: EmbeddingIndex
    private let settingsProvider: () -> AppSettings

    init(meetings: @escaping () -> [Meeting],
         storage: StorageManager,
         searchIndex: SearchIndex,
         embeddingIndex: EmbeddingIndex,
         settings: @escaping () -> AppSettings) {
        self.meetingsProvider = meetings
        self.storage = storage
        self.searchIndex = searchIndex
        self.embeddingIndex = embeddingIndex
        self.settingsProvider = settings
    }

    let specs: [ChatToolSpec] = [
        ChatToolSpec(
            name: "search_meetings",
            summary: "Search across every meeting transcript, summary and title. Accepts natural-language or keyword queries; returns matching meetings with timestamps and snippets.",
            arguments: [
                .init(name: "query", description: "What to look for, in natural language or keywords.", required: true),
            ]),
        ChatToolSpec(
            name: "list_meetings",
            summary: "List recorded meetings, newest first, optionally filtered by a title substring.",
            arguments: [
                .init(name: "query", description: "Optional case-insensitive title filter.", required: false),
                .init(name: "limit", description: "Maximum number to return (default 15).", required: false),
            ]),
        ChatToolSpec(
            name: "get_meeting",
            summary: "Read one meeting's summary or full transcript.",
            arguments: [
                .init(name: "id", description: "Meeting id from another tool's output, or 'latest' for the most recent.", required: true),
                .init(name: "include", description: "What to return: 'summary' (default), 'transcript', or 'all'.", required: false),
            ]),
    ]

    func libraryOverview() -> String {
        MeetingChatFormat.libraryOverview(meetingsProvider(), limit: 12)
    }

    func run(_ call: ChatToolCall) async -> ChatToolResult {
        switch call.name {
        case "search_meetings": return await search(call)
        case "list_meetings": return list(call)
        case "get_meeting": return get(call)
        default: return ChatToolResult(text: "Unknown tool '\(call.name)'.", summary: "unknown tool")
        }
    }

    // MARK: - Tools

    private func search(_ call: ChatToolCall) async -> ChatToolResult {
        guard let query = call.string("query") else {
            return ChatToolResult(text: "Provide a 'query' argument.", summary: "missing query")
        }
        let meetings = meetingsProvider()
        var keyword = searchIndex.search(query, limit: 8)
        if keyword.isEmpty {
            // A natural-language question ANDs every stop word against the index and
            // misses; retry on content keywords with OR semantics (ranked by FTS)
            // before reporting nothing.
            keyword = searchIndex.search(query, limit: 8, matchAll: false, dropStopWords: true)
        }
        var semantic: [EmbeddingIndex.Hit] = []
        if settingsProvider().semanticSearchEnabled, embeddingIndex.hasEmbeddings {
            // Drop semantic chunks already surfaced by keyword search.
            let seen = Set(keyword.map { "\($0.meetingID)-\(Int($0.start))" })
            semantic = await embeddingIndex.search(query, limit: 5)
                .filter { !seen.contains("\($0.meetingID)-\(Int($0.start))") }
        }
        let text = MeetingChatFormat.searchResults(query: query, keyword: keyword,
                                                   semantic: semantic, meetings: meetings)
        let count = keyword.count + semantic.count
        return ChatToolResult(text: text,
                              summary: "“\(query)” — \(count) match\(count == 1 ? "" : "es")")
    }

    private func list(_ call: ChatToolCall) -> ChatToolResult {
        var meetings = meetingsProvider()
        if let filter = call.string("query") {
            meetings = meetings.filter { $0.title.localizedCaseInsensitiveContains(filter) }
        }
        let limit = max(1, min(call.int("limit") ?? 15, 50))
        meetings = Array(meetings.prefix(limit))
        return ChatToolResult(text: MeetingChatFormat.list(meetings),
                              summary: "\(meetings.count) meeting\(meetings.count == 1 ? "" : "s")")
    }

    private func get(_ call: ChatToolCall) -> ChatToolResult {
        let meetings = meetingsProvider()
        let idArgument = call.string("id") ?? "latest"
        guard let meeting = resolve(idArgument, in: meetings) else {
            return ChatToolResult(
                text: "No meeting matches '\(idArgument)'. Use list_meetings to see ids.",
                summary: "no match for \(idArgument)")
        }
        let folder = meeting.folderURL(in: storage)
        let summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        let transcript = try? String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        let include = call.string("include") ?? "summary"
        let text = MeetingChatFormat.meeting(meeting, summary: summary,
                                             transcript: transcript, include: include)
        return ChatToolResult(text: text, summary: meeting.title)
    }

    /// Resolve by short id / full uuid / 'latest' (via `SessionLookup`, pinned to
    /// the in-memory list we pass it so it never touches the hard-coded library
    /// path), then fall back to a title substring match.
    private func resolve(_ idArgument: String, in meetings: [Meeting]) -> Meeting? {
        if let found = (try? SessionLookup.find(id: idArgument, in: meetings)) ?? nil {
            return found
        }
        return meetings.first { $0.title.localizedCaseInsensitiveContains(idArgument) }
    }
}
