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
    var limit: Int = LibrarySearch.defaultLimit

    @Flag(name: .long, help: "Plain-text table instead of JSON.")
    var table: Bool = false

    func run() async throws {
        let hits = try LibrarySearch.hits(query: query, limit: limit)
        print(table
            ? SessionFormatter.searchTable(hits)
            : SessionFormatter.searchJSON(hits))
    }
}
