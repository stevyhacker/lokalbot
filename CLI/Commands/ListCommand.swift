import ArgumentParser
import Foundation

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List meetings, newest first.",
        discussion: """
            JSON by default — one object per meeting with id, title, date,
            duration, `has_system_track`, `has_summary`, `has_transcript`.
            Use --table for human-readable output.
            """
    )

    @Option(name: .long, help: "Only include meetings on or after this date (YYYY-MM-DD).")
    var since: String?

    @Option(name: .long, help: "Only include meetings on or before this date (YYYY-MM-DD).")
    var until: String?

    @Option(name: .long, help: "Substring match against the title (case-insensitive).")
    var query: String?

    @Option(name: .long, help: "Maximum number of meetings to return.")
    var limit: Int?

    @Flag(name: .long, help: "Plain-text table instead of JSON.")
    var table: Bool = false

    func run() async throws {
        try AgentAccessGate().requireAuthorized()
        let sinceDate = try since.map { try Self.requireDate($0, option: "--since") }
        let untilDate = try until.map { try Self.requireDate($0, option: "--until") }
        if let limit, !(1...LibraryInputPolicy.maximumMeetingCount).contains(limit) {
            throw ValidationError(
                "--limit must be between 1 and \(LibraryInputPolicy.maximumMeetingCount).")
        }
        var meetings = try SessionLookup.loadAllMeetings()

        if let date = sinceDate {
            meetings = meetings.filter { $0.startedAt >= date }
        }
        if let date = untilDate {
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
            meetings = meetings.filter { $0.startedAt < endOfDay }
        }
        if let query {
            meetings = meetings.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        if let limit {
            meetings = Array(meetings.prefix(limit))
        }

        print(table
            ? SessionFormatter.listTable(meetings)
            : SessionFormatter.listJSON(meetings))
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }

    private static func requireDate(_ value: String, option: String) throws -> Date {
        guard let date = parseDate(value) else {
            throw ValidationError("\(option) must use YYYY-MM-DD, got '\(value)'.")
        }
        return date
    }
}
