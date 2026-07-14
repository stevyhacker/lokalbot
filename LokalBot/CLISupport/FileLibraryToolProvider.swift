import Foundation

/// File-backed MCP provider. Read tools work while the app is closed;
/// `ask_library` delegates to an injected local-model engine.
struct FileLibraryToolProvider: LibraryToolProvider {
    var gate: AgentAccessGate
    var screenGate: ScreenMemoryAccessGate
    var screenReader: any ScreenMemoryReading
    var now: () -> Date
    var ask: (String) async -> ToolResult

    init(
        gate: AgentAccessGate,
        screenGate: ScreenMemoryAccessGate? = nil,
        screenReader: (any ScreenMemoryReading)? = nil,
        now: @escaping () -> Date = Date.init,
        ask: @escaping (String) async -> ToolResult
    ) {
        self.gate = gate
        self.screenGate = screenGate ?? ScreenMemoryAccessGate(root: gate.root)
        self.screenReader = screenReader ?? SQLiteScreenMemoryReader(
            databaseURL: gate.root.appendingPathComponent("lokalbotv3.sqlite"))
        self.now = now
        self.ask = ask
    }

    static let accessDisabledMessage =
        "External agent access is off. Enable it in LokalBot → Settings → Privacy → " +
        "\"Allow external agents to read your meeting library\"."

    static let screenAccessDisabledMessage =
        "External screen-memory access is off. Enable it separately in LokalBot → " +
        "Settings → Privacy → \"Allow external agents to read screen memory\"."

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
            ToolDefinition(
                name: "search_screen",
                description: "Search locally extracted screen OCR and window titles. Returns OCR snippets and screenshot metadata only; never pixels or screenshot file paths. Requires the separate screen-memory permission.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Text to search for."],
                        "day": ["type": "string", "description": "Optional local calendar day (YYYY-MM-DD)."],
                        "app": ["type": "string", "description": "Optional app-name substring."],
                        "limit": ["type": "integer", "description": "Maximum hits (default 40, maximum 200)."],
                    ],
                    "required": ["query"],
                ]),
            ToolDefinition(
                name: "get_timeline",
                description: "Get activity blocks and screenshot metadata for one local calendar day. No screenshot pixels or file paths are returned. Requires the separate screen-memory permission.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "day": ["type": "string", "description": "Local calendar day (YYYY-MM-DD); defaults to today."],
                        "limit": ["type": "integer", "description": "Maximum activity blocks and screenshots (default 200, maximum 500)."],
                    ],
                ]),
            ToolDefinition(
                name: "get_recent_activity",
                description: "Get recent app/window activity blocks, newest first. Requires the separate screen-memory permission.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "minutes": ["type": "integer", "description": "Lookback window in minutes (default 120, maximum 10080)."],
                        "limit": ["type": "integer", "description": "Maximum blocks (default 50, maximum 200)."],
                    ],
                ]),
            ToolDefinition(
                name: "get_app_usage",
                description: "Aggregate tracked time by app for one local calendar day. Requires the separate screen-memory permission.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "day": ["type": "string", "description": "Local calendar day (YYYY-MM-DD); defaults to today."],
                        "limit": ["type": "integer", "description": "Maximum apps (default 30, maximum 100)."],
                    ],
                ]),
            ToolDefinition(
                name: "get_screenshot_detail",
                description: "Get OCR text and metadata for one screenshot id. It reports whether encrypted pixels exist but never returns decrypted pixels or a file path. Requires the separate screen-memory permission.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "snapshot_id": ["type": "integer", "description": "Screenshot id returned by search_screen or get_timeline."],
                    ],
                    "required": ["snapshot_id"],
                ]),
        ]
    }

    func call(name: String, arguments: JSONValue?) async -> ToolResult {
        if Self.meetingToolNames.contains(name), !gate.isAuthorized() {
            return .error(.accessDisabled, Self.accessDisabledMessage)
        }
        if Self.screenToolNames.contains(name), !screenGate.isAuthorized() {
            return .error(.screenAccessDisabled, Self.screenAccessDisabledMessage)
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
        case "search_screen":
            return searchScreen(arguments)
        case "get_timeline":
            return getTimeline(arguments)
        case "get_recent_activity":
            return getRecentActivity(arguments)
        case "get_app_usage":
            return getAppUsage(arguments)
        case "get_screenshot_detail":
            return getScreenshotDetail(arguments)
        default:
            return .error(
                .unknownTool,
                "No tool named \"\(name)\". Available: \(tools.map(\.name).joined(separator: ", ")).")
        }
    }

    private static let meetingToolNames: Set<String> = [
        "list_meetings", "get_meeting", "search_meetings", "ask_library",
    ]
    private static let screenToolNames: Set<String> = [
        "search_screen", "get_timeline", "get_recent_activity", "get_app_usage",
        "get_screenshot_detail",
    ]

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
            let limit: Int
            switch boundedLimit(arguments?["limit"], default: 20,
                                maximum: LibraryInputPolicy.maximumMeetingCount) {
            case .success(let value): limit = value
            case .failure(let result): return result
            }
            return .text(SessionFormatter.listJSON(Array(meetings.prefix(limit))))
        } catch {
            return .error(
                .meetingNotFound,
                "Could not read the meeting library: \(error.localizedDescription)")
        }
    }

    private func getMeeting(_ arguments: JSONValue?) -> ToolResult {
        guard let id = arguments?["id"]?.stringValue, !id.isEmpty,
              id.count <= 64 else {
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
        guard let query = arguments?["query"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty,
              query.count <= LibraryInputPolicy.maximumQueryCharacters else {
            return .error(
                .invalidArguments,
                "search_meetings requires a non-empty \"query\" string of at most \(LibraryInputPolicy.maximumQueryCharacters) characters.")
        }
        do {
            let limit: Int
            switch boundedLimit(arguments?["limit"], default: LibrarySearch.defaultLimit,
                                maximum: LibraryInputPolicy.maximumSearchHits) {
            case .success(let value): limit = value
            case .failure(let result): return result
            }
            return .text(SessionFormatter.searchJSON(
                try LibrarySearch.hits(query: query, limit: limit)))
        } catch {
            return .error(
                .meetingNotFound,
                "Could not read the meeting library: \(error.localizedDescription)")
        }
    }

    // MARK: - Screen memory (separately authorized)

    private func searchScreen(_ arguments: JSONValue?) -> ToolResult {
        guard let query = arguments?["query"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty,
              query.count <= LibraryInputPolicy.maximumQueryCharacters else {
            return .error(
                .invalidArguments,
                "search_screen requires a non-empty \"query\" string of at most \(LibraryInputPolicy.maximumQueryCharacters) characters.")
        }
        let limit: Int
        switch boundedInteger(arguments?["limit"], name: "limit", default: 40, maximum: 200) {
        case .success(let value): limit = value
        case .failure(let result): return result
        }
        let interval: DateInterval?
        if arguments?["day"] != nil {
            switch localDayInterval(arguments?["day"], name: "day") {
            case .success(let value): interval = value
            case .failure(let result): return result
            }
        } else {
            interval = nil
        }
        let app = arguments?["app"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let app, app.count > 200 {
            return .error(.invalidArguments, "\"app\" must be at most 200 characters.")
        }
        do {
            let hits = try screenReader.search(ScreenMemorySearchRequest(
                query: query,
                start: interval?.start,
                end: interval?.end,
                app: app,
                limit: limit))
            return .text(encodeScreenMemory(hits))
        } catch {
            return screenMemoryFailure(error)
        }
    }

    private func getTimeline(_ arguments: JSONValue?) -> ToolResult {
        let interval: DateInterval
        switch localDayInterval(arguments?["day"], name: "day") {
        case .success(let value): interval = value
        case .failure(let result): return result
        }
        let limit: Int
        switch boundedInteger(arguments?["limit"], name: "limit", default: 200, maximum: 500) {
        case .success(let value): limit = value
        case .failure(let result): return result
        }
        do {
            return .text(encodeScreenMemory(try screenReader.timeline(
                from: interval.start, to: interval.end, limit: limit)))
        } catch {
            return screenMemoryFailure(error)
        }
    }

    private func getRecentActivity(_ arguments: JSONValue?) -> ToolResult {
        let minutes: Int
        switch boundedInteger(
            arguments?["minutes"], name: "minutes", default: 120, maximum: 10_080
        ) {
        case .success(let value): minutes = value
        case .failure(let result): return result
        }
        let limit: Int
        switch boundedInteger(arguments?["limit"], name: "limit", default: 50, maximum: 200) {
        case .success(let value): limit = value
        case .failure(let result): return result
        }
        do {
            let start = now().addingTimeInterval(-TimeInterval(minutes * 60))
            return .text(encodeScreenMemory(
                try screenReader.recentActivity(since: start, limit: limit)))
        } catch {
            return screenMemoryFailure(error)
        }
    }

    private func getAppUsage(_ arguments: JSONValue?) -> ToolResult {
        let interval: DateInterval
        switch localDayInterval(arguments?["day"], name: "day") {
        case .success(let value): interval = value
        case .failure(let result): return result
        }
        let limit: Int
        switch boundedInteger(arguments?["limit"], name: "limit", default: 30, maximum: 100) {
        case .success(let value): limit = value
        case .failure(let result): return result
        }
        do {
            return .text(encodeScreenMemory(try screenReader.appUsage(
                from: interval.start, to: interval.end, limit: limit)))
        } catch {
            return screenMemoryFailure(error)
        }
    }

    private func getScreenshotDetail(_ arguments: JSONValue?) -> ToolResult {
        guard let id = arguments?["snapshot_id"]?.intValue, id > 0 else {
            return .error(
                .invalidArguments,
                "get_screenshot_detail requires a positive integer \"snapshot_id\".")
        }
        do {
            guard let detail = try screenReader.screenshotDetail(snapshotID: Int64(id)) else {
                return .error(
                    .screenshotNotFound,
                    "No screenshot metadata matches id \(id). Use search_screen or get_timeline to find ids.")
            }
            return .text(encodeScreenMemory(detail))
        } catch {
            return screenMemoryFailure(error)
        }
    }

    private func screenMemoryFailure(_ error: Error) -> ToolResult {
        .error(
            .screenMemoryUnavailable,
            "Could not read local screen memory: \(error.localizedDescription)")
    }

    private func encodeScreenMemory<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private enum DayIntervalResult {
        case success(DateInterval)
        case failure(ToolResult)
    }

    private func localDayInterval(_ raw: JSONValue?, name: String) -> DayIntervalResult {
        let calendar = Calendar.current
        let day: Date
        if let raw {
            guard let value = raw.stringValue,
                  let parsed = Self.parseLocalDay(value, calendar: calendar) else {
                return .failure(.error(
                    .invalidArguments,
                    "\"\(name)\" must be a real local calendar day formatted YYYY-MM-DD."))
            }
            day = parsed
        } else {
            day = now()
        }
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return .success(DateInterval(start: start, end: end))
    }

    private static func parseLocalDay(_ value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let parsed = calendar.date(from: DateComponents(
                calendar: calendar, timeZone: calendar.timeZone,
                year: year, month: month, day: day)) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: parsed)
        guard components.year == year, components.month == month, components.day == day else {
            return nil
        }
        return parsed
    }

    private enum LimitResult {
        case success(Int)
        case failure(ToolResult)
    }

    private func boundedLimit(_ raw: JSONValue?, default defaultValue: Int,
                              maximum: Int) -> LimitResult {
        boundedInteger(raw, name: "limit", default: defaultValue, maximum: maximum)
    }

    private func boundedInteger(_ raw: JSONValue?, name: String, default defaultValue: Int,
                                maximum: Int) -> LimitResult {
        guard let raw else { return .success(defaultValue) }
        guard let value = raw.intValue, (1...maximum).contains(value) else {
            return .failure(.error(
                .invalidArguments,
                "\"\(name)\" must be an integer between 1 and \(maximum)."))
        }
        return .success(value)
    }
}
