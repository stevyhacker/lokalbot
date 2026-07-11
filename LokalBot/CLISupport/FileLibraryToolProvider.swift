import Foundation

/// File-backed MCP provider. Read tools work while the app is closed;
/// `ask_library` delegates to an injected local-model engine.
struct FileLibraryToolProvider: LibraryToolProvider {
    var gate: AgentAccessGate
    var ask: (String) async -> ToolResult

    static let accessDisabledMessage =
        "External agent access is off. Enable it in LokalBot → Settings → Privacy → " +
        "\"Allow external agents to read your meeting library\"."

    var tools: [ToolDefinition] {
        [
            ToolDefinition(
                name: "list_meetings",
                description: "List recorded meetings, newest first. Returns id, title, date, and duration for each.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "limit": [
                            "type": "integer",
                            "description": "Maximum meetings to return (default 20).",
                        ],
                        "since": [
                            "type": "string",
                            "description": "Only meetings on or after this UTC day, formatted YYYY-MM-DD.",
                        ],
                        "query": [
                            "type": "string",
                            "description": "Case-insensitive title substring filter.",
                        ],
                    ],
                ]),
            ToolDefinition(
                name: "get_meeting",
                description: "Fetch one meeting as markdown. Sections: metadata, summary, transcript.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "Short id from list_meetings, full UUID, or \"latest\".",
                        ],
                        "include": [
                            "type": "string",
                            "description": "Comma-separated subset of metadata,summary,transcript. Default: all three.",
                        ],
                    ],
                    "required": ["id"],
                ]),
            ToolDefinition(
                name: "search_meetings",
                description: "Case-insensitive substring search across meeting titles, summaries, and transcripts. Hits are recency-ordered with kind, snippet, and timestamp.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Text to search for."],
                        "limit": ["type": "integer", "description": "Maximum hits (default 50)."],
                    ],
                    "required": ["query"],
                ]),
            ToolDefinition(
                name: "ask_library",
                description: "Ask a question and get an answer synthesized by LokalBot's local model from the meeting library, with meeting citations — raw transcripts never leave the Mac. Needs the LokalBot app running; the first call may take up to a minute while the model loads.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "question": [
                            "type": "string",
                            "description": "The question to answer from the user's meetings.",
                        ],
                    ],
                    "required": ["question"],
                ]),
        ]
    }

    func call(name: String, arguments: JSONValue?) async -> ToolResult {
        guard gate.isEnabled else {
            return .error(.accessDisabled, Self.accessDisabledMessage)
        }

        switch name {
        case "list_meetings":
            return listMeetings(arguments)
        case "get_meeting":
            return getMeeting(arguments)
        case "search_meetings":
            return searchMeetings(arguments)
        case "ask_library":
            guard let question = arguments?["question"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !question.isEmpty else {
                return .error(
                    .invalidArguments,
                    "ask_library requires a non-empty \"question\" string.")
            }
            return await ask(question)
        default:
            return .error(
                .unknownTool,
                "No tool named \"\(name)\". Available: list_meetings, get_meeting, search_meetings, ask_library.")
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func listMeetings(_ arguments: JSONValue?) -> ToolResult {
        do {
            var meetings = try SessionLookup.loadAllMeetings()
            if let query = arguments?["query"]?.stringValue, !query.isEmpty {
                let needle = query.lowercased()
                meetings = meetings.filter { $0.title.lowercased().contains(needle) }
            }
            if let since = arguments?["since"]?.stringValue {
                guard let day = Self.dayFormatter.date(from: since) else {
                    return .error(
                        .invalidArguments,
                        "\"since\" must be formatted YYYY-MM-DD, got \"\(since)\".")
                }
                meetings = meetings.filter { $0.startedAt >= day }
            }
            let limit = max(1, arguments?["limit"]?.intValue ?? 20)
            return .text(SessionFormatter.listJSON(Array(meetings.prefix(limit))))
        } catch {
            return .error(
                .meetingNotFound,
                "Could not read the meeting library: \(error.localizedDescription)")
        }
    }

    private func getMeeting(_ arguments: JSONValue?) -> ToolResult {
        guard let id = arguments?["id"]?.stringValue, !id.isEmpty else {
            return .error(
                .invalidArguments,
                "get_meeting requires an \"id\" string (short id, full UUID, or \"latest\").")
        }

        do {
            let meetings = try SessionLookup.loadAllMeetings()
            let needle = id.lowercased()
            if needle != "latest", UUID(uuidString: needle) == nil {
                let matches = meetings.filter {
                    SessionLookup.shortID($0.id).hasPrefix(needle)
                }
                if matches.count > 1 {
                    let ids = matches.map { SessionLookup.shortID($0.id) }
                        .joined(separator: ", ")
                    return .error(
                        .ambiguousID,
                        "\"\(id)\" matches several meetings (\(ids)). Use a longer id.")
                }
            }
            guard let meeting = try SessionLookup.find(id: id, in: meetings) else {
                return .error(
                    .meetingNotFound,
                    "No meeting matches \"\(id)\". Use list_meetings or search_meetings to find ids.")
            }
            return .text(SessionFormatter.getMarkdown(
                meeting,
                options: parseInclude(arguments?["include"]?.stringValue)))
        } catch {
            return .error(
                .meetingNotFound,
                "Could not read the meeting library: \(error.localizedDescription)")
        }
    }

    private func parseInclude(_ include: String?) -> SessionFormatter.GetOptions {
        guard let include, !include.isEmpty else { return .all }
        let parts = Set(include.lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) })
        return .init(
            includeSummary: parts.contains("summary"),
            includeTranscript: parts.contains("transcript"),
            includeMetadata: parts.contains("metadata"))
    }

    private func searchMeetings(_ arguments: JSONValue?) -> ToolResult {
        guard let query = arguments?["query"]?.stringValue, !query.isEmpty else {
            return .error(
                .invalidArguments,
                "search_meetings requires a non-empty \"query\" string.")
        }
        do {
            let limit = max(1, arguments?["limit"]?.intValue ?? LibrarySearch.defaultLimit)
            return .text(SessionFormatter.searchJSON(
                try LibrarySearch.hits(query: query, limit: limit)))
        } catch {
            return .error(
                .meetingNotFound,
                "Could not read the meeting library: \(error.localizedDescription)")
        }
    }
}
