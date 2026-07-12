import ArgumentParser
import Foundation

struct InstallSkillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-skill",
        abstract: "Install the LokalBot skill and CLI symlinks for coding agents.",
        discussion: """
            Symlinks the app-bundled skill into ~/.agents/skills/lokalbot-cli
            and ~/.claude/skills/lokalbot-cli, and this binary into
            ~/.local/bin/lokalbot-cli. Symlinks track app updates
            automatically; pass --copy if your agent can't follow symlinks.
            Nothing is installed unless you run this.
            """)

    @Flag(name: .long, help: "Copy the skill directories instead of symlinking.")
    var copy = false

    @Flag(name: .long, help: "Remove everything install-skill created.")
    var uninstall = false

    func run() async throws {
        guard let installer = LokalBotCLIInstaller.fromCurrentBinary() else {
            throw ValidationError("""
                This binary isn't inside LokalBot.app, so there is no bundled \
                skill to install. Run the embedded helper instead:
                  /Applications/LokalBot.app/Contents/Helpers/lokalbot-cli install-skill
                """)
        }
        if uninstall {
            try installer.uninstall()
            print("Removed the lokalbot-cli symlinks and skill installs.")
            return
        }

        try installer.install(skillMode: copy ? .copy : .symlink)
        let helper = installer.bundledBinary?.path
            ?? "/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli"
        print("""
            Installed:
              \(installer.binLink.path)
              \(installer.skillLink.path)
              \(installer.claudeSkillLink.path)

            Claude Code picks the skill up automatically; point other agents
            at one of the skill directories above.

            MCP clients (Claude Desktop, ...) can add the same library with:
              claude mcp add lokalbot -- \(helper) mcp
            """)
        if !installer.localBinOnPath {
            print("""

                Note: ~/.local/bin isn't on your PATH. Add it with:
                  echo '\(LokalBotCLIInstaller.pathExportLine)' >> ~/.zshrc
                """)
        }
    }
}
