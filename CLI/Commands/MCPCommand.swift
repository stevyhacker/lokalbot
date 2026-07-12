import ArgumentParser
import Foundation

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the meeting library over MCP (stdio, JSON-RPC 2.0).",
        discussion: """
            For GUI agent clients (Claude Desktop, and any MCP-capable app):

              claude mcp add lokalbot -- \
                /Applications/LokalBot.app/Contents/Helpers/lokalbot-cli mcp

            Tools: list_meetings, get_meeting, search_meetings, ask_library.
            Read tools work with the app closed; ask_library needs the app
            running (it answers with the local model on localhost:17872).

            All tools require the Privacy toggle: LokalBot → Settings →
            Privacy → "Allow external agents to read your meeting library".
            While it is off, the handshake still succeeds and every call
            returns a structured access_disabled error with enable steps.
            """)

    func run() async throws {
        let gate = AgentAccessGate()
        let engine = AskLibraryEngine(gate: gate)
        let provider = FileLibraryToolProvider(gate: gate) { question in
            await engine.ask(question)
        }
        let dispatcher = MCPDispatcher(
            provider: provider,
            serverVersion: HelperVersion.current())

        FileHandle.standardError.write(Data(
            "lokalbot-cli mcp: serving on stdio (library: \(SessionLookup.storageRootURL.path))\n".utf8))

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = await dispatcher.handle(line: line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }
}
