import ArgumentParser
import Foundation

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Substring search across titles, summaries, and transcripts.",
        discussion: """
            Returns up to 50 hits ordered by meeting recency. Case-insensitive
            substring match. JSON by default; pass --table for a quick scan.

            For agent use, prefer the in-app FTS5 index (richer ranking +
            snippets) — this lightweight CLI search just walks the on-disk
            artifacts so it works without launching the app.
            """
    )

    @Argument(help: "Query string. Substring match, case-insensitive.")
    var query: String

    @Option(name: .long, help: "Maximum number of hits to return.")
    var limit: Int = 50

    @Flag(name: .long, help: "Plain-text table instead of JSON.")
    var table: Bool = false

    func run() async throws {
        let needle = query.lowercased()
        let meetings = try SessionLookup.loadAllMeetings()

        var hits: [SessionFormatter.SearchHit] = []
        for meeting in meetings {
            let short = SessionLookup.shortID(meeting.id)
            if meeting.title.lowercased().contains(needle) {
                hits.append(.init(meeting_id: short, meeting_title: meeting.title,
                                  match_kind: "title", snippet: meeting.title, timestamp: nil))
            }
            if let summary = SessionLookup.summaryMarkdown(for: meeting),
               let snippet = Self.snippet(in: summary, around: needle) {
                hits.append(.init(meeting_id: short, meeting_title: meeting.title,
                                  match_kind: "summary", snippet: snippet, timestamp: nil))
            }
            if let transcript = SessionLookup.transcript(for: meeting) {
                for segment in transcript.segments where segment.text.lowercased().contains(needle) {
                    hits.append(.init(
                        meeting_id: short,
                        meeting_title: meeting.title,
                        match_kind: "transcript",
                        snippet: segment.text,
                        timestamp: Transcript.stamp(segment.start)))
                    if hits.count >= limit { break }
                }
            }
            if hits.count >= limit { break }
        }
        hits = Array(hits.prefix(limit))
        print(table
            ? SessionFormatter.searchTable(hits)
            : SessionFormatter.searchJSON(hits))
    }

    /// 80-char window around the first occurrence of `needle`, with leading/
    /// trailing ellipsis when truncated. Case-insensitive search; returns the
    /// original-case substring so the user reads what they wrote.
    private static func snippet(in haystack: String, around needle: String) -> String? {
        guard let range = haystack.lowercased().range(of: needle) else { return nil }
        let start = haystack.index(range.lowerBound,
                                   offsetBy: -40, limitedBy: haystack.startIndex) ?? haystack.startIndex
        let end = haystack.index(range.upperBound,
                                 offsetBy: 40, limitedBy: haystack.endIndex) ?? haystack.endIndex
        var snippet = String(haystack[start..<end])
        if start != haystack.startIndex { snippet = "…" + snippet }
        if end != haystack.endIndex { snippet += "…" }
        return snippet
    }
}
