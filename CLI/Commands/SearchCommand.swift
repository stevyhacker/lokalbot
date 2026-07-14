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
        try AgentAccessGate().requireAuthorized()
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw ValidationError("Query must not be empty.")
        }
        guard normalizedQuery.count <= LibraryInputPolicy.maximumQueryCharacters else {
            throw ValidationError(
                "Query must be at most \(LibraryInputPolicy.maximumQueryCharacters) characters.")
        }
        guard (1...LibraryInputPolicy.maximumSearchHits).contains(limit) else {
            throw ValidationError(
                "--limit must be between 1 and \(LibraryInputPolicy.maximumSearchHits).")
        }
        let hits = try LibrarySearch.hits(query: normalizedQuery, limit: limit)
        print(table
            ? SessionFormatter.searchTable(hits)
            : SessionFormatter.searchJSON(hits))
    }
}
