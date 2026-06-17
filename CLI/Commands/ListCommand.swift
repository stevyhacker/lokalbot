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
        var meetings = try SessionLookup.loadAllMeetings()

        if let since, let date = Self.parseDate(since) {
            meetings = meetings.filter { $0.startedAt >= date }
        }
        if let until, let date = Self.parseDate(until) {
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
}
