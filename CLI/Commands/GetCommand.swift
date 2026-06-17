import ArgumentParser
import Foundation

struct GetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Print one meeting as Markdown (default) or JSON.",
        discussion: """
            ID comes from `list` output, or the literal `latest` to pick the
            most recent meeting. By default the Markdown includes metadata,
            summary, and transcript. Restrict with --include.
            """
    )

    @Argument(help: "Meeting ID from `list`, or 'latest' for the most recent.")
    var id: String

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Comma-separated parts to include.",
            discussion: "Choose any of: metadata, summary, transcript. Default is all three."
        )
    )
    var include: String = "metadata,summary,transcript"

    @Option(name: .long, help: "Output format: md (default) or json.")
    var format: String = "md"

    func run() async throws {
        guard let meeting = try SessionLookup.find(id: id) else {
            throw ValidationError("No meeting with id '\(id)'. Run `list` to see available IDs.")
        }
        let options = parseOptions()
        switch format.lowercased() {
        case "md":
            print(SessionFormatter.getMarkdown(meeting, options: options))
        case "json":
            print(SessionFormatter.getJSON(meeting, options: options))
        default:
            throw ValidationError("Unknown format '\(format)'. Use 'md' or 'json'.")
        }
    }

    private func parseOptions() -> SessionFormatter.GetOptions {
        let parts = include.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return SessionFormatter.GetOptions(
            includeSummary: parts.contains("summary"),
            includeTranscript: parts.contains("transcript"),
            includeMetadata: parts.contains("metadata"))
    }
}
