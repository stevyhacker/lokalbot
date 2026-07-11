import Foundation
import os

private let logger = Logger(
    subsystem: AppIdentifiers.appBundleID,
    category: "CLIInstaller")

/// Installs the bundled CLI and skill for shell agents. The binary always
/// stays symlinked into the app so Sparkle updates keep it current; skills can
/// be linked or copied. Both ~/.agents/skills and ~/.claude/skills are served.
struct LokalBotCLIInstaller {
    var home: URL
    var bundledBinary: URL?
    var bundledSkillDir: URL?
    var fileManager: FileManager
    var environment: [String: String]

    static var bundled: LokalBotCLIInstaller {
        let fileManager = FileManager.default
        let helper = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/lokalbot-cli")
        let skill = Bundle.main.resourceURL?.appending(path: "lokalbot-cli")
        return LokalBotCLIInstaller(
            home: fileManager.homeDirectoryForCurrentUser,
            bundledBinary: fileManager.fileExists(atPath: helper.path) ? helper : nil,
            bundledSkillDir: skill.flatMap {
                fileManager.fileExists(atPath: $0.path) ? $0 : nil
            },
            fileManager: fileManager,
            environment: ProcessInfo.processInfo.environment)
    }

    /// Resolves the app bundle from the embedded helper's own argv[0].
    static func fromCurrentBinary(
        path: String = CommandLine.arguments[0],
        fileManager: FileManager = .default
    ) -> LokalBotCLIInstaller? {
        let binary = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let contents = binary
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return nil }
        let skill = contents.appending(path: "Resources/lokalbot-cli")
        guard fileManager.fileExists(atPath: binary.path),
              fileManager.fileExists(atPath: skill.path) else {
            return nil
        }
        return LokalBotCLIInstaller(
            home: fileManager.homeDirectoryForCurrentUser,
            bundledBinary: binary,
            bundledSkillDir: skill,
            fileManager: fileManager,
            environment: ProcessInfo.processInfo.environment)
    }

    var binLink: URL { home.appending(path: ".local/bin/lokalbot-cli") }
    var skillLink: URL { home.appending(path: ".agents/skills/lokalbot-cli") }
    var claudeSkillLink: URL { home.appending(path: ".claude/skills/lokalbot-cli") }

    static let copyMarkerName = ".lokalbot-skill-copy"
    static let pathExportLine = #"export PATH="$HOME/.local/bin:$PATH""#

    enum SkillMode {
        case symlink
        case copy
    }

    var touchedPaths: [String] {
        [
            "~/.local/bin/lokalbot-cli",
            "~/.agents/skills/lokalbot-cli",
            "~/.claude/skills/lokalbot-cli",
        ]
    }

    var isInstalled: Bool {
        guard let binary = bundledBinary, let skill = bundledSkillDir else {
            return false
        }
        return symlink(binLink, resolvesTo: binary)
            && symlink(skillLink, resolvesTo: skill)
    }

    var isBundleLocationStable: Bool {
        guard let binary = bundledBinary else { return false }
        if binary.path.contains("/AppTranslocation/") { return false }
        let bundle = binary
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return false
        }
        return true
    }

    static let agentConfigDirNames = [
        ".claude", ".codex", ".cursor", ".gemini", ".agents",
    ]

    var hasAgentConfigDir: Bool {
        Self.agentConfigDirNames.contains {
            isExistingDirectory(home.appending(path: $0))
        }
    }

    var localBinOnPath: Bool {
        let path = environment["PATH"] ?? ""
        let candidate = "\(home.path)/.local/bin"
        return path.split(separator: ":").contains { $0 == candidate }
    }

    enum InstallError: LocalizedError {
        case bundleNotShipped
        case bundleNotStable
        case fileSystem(String)

        var errorDescription: String? {
            switch self {
            case .bundleNotShipped:
                "This build doesn't ship the lokalbot-cli — install the latest release."
            case .bundleNotStable:
                "The app is running from a translocated or read-only location. Move LokalBot.app to /Applications and relaunch."
            case .fileSystem(let message):
                message
            }
        }
    }

    func install(skillMode: SkillMode = .symlink) throws {
        guard let binary = bundledBinary, let skill = bundledSkillDir else {
            throw InstallError.bundleNotShipped
        }
        guard isBundleLocationStable else { throw InstallError.bundleNotStable }

        try ensureDirectory(binLink.deletingLastPathComponent())
        try replaceSymlink(at: binLink, target: binary)
        for link in [skillLink, claudeSkillLink] {
            try ensureDirectory(link.deletingLastPathComponent())
            switch skillMode {
            case .symlink:
                try replaceSymlink(at: link, target: skill)
            case .copy:
                try replaceWithCopy(at: link, of: skill)
            }
        }
        logger.info("CLI installed at \(binLink.path) -> \(binary.path)")
    }

    /// Removes only LokalBot links and copies stamped by this installer.
    func uninstall() throws {
        for link in [binLink, skillLink, claudeSkillLink] {
            if let destination = try? fileManager.destinationOfSymbolicLink(
                atPath: link.path) {
                if destination.contains("LokalBot.app/")
                    || destination.contains("LokalBotV3.app/") {
                    try fileManager.removeItem(at: link)
                }
            } else if isExistingDirectory(link),
                      fileManager.fileExists(atPath: link
                        .appendingPathComponent(Self.copyMarkerName).path) {
                try fileManager.removeItem(at: link)
            }
        }
        logger.info("CLI uninstalled")
    }

    func addLocalBinToPath() throws {
        let zshrc = home.appending(path: ".zshrc")
        let existing = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        guard !existing.contains(Self.pathExportLine) else { return }
        var updated = existing
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
        updated += "\n# Added by LokalBot / lokalbot-cli\n\(Self.pathExportLine)\n"
        do {
            try updated.write(to: zshrc, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.fileSystem(
                "Could not write to ~/.zshrc: \(error.localizedDescription)")
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw InstallError.fileSystem(
                "Could not create \(url.path): \(error.localizedDescription)")
        }
    }

    private func replaceSymlink(at link: URL, target: URL) throws {
        if symlink(link, resolvesTo: target) { return }
        if fileManager.fileExists(atPath: link.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try fileManager.removeItem(at: link)
        }
        do {
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        } catch {
            throw InstallError.fileSystem(
                "Could not create symlink at \(link.path): \(error.localizedDescription)")
        }
    }

    private func replaceWithCopy(at destination: URL, of source: URL) throws {
        if fileManager.fileExists(atPath: destination.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.copyItem(at: source, to: destination)
            try Data().write(to: destination.appendingPathComponent(Self.copyMarkerName))
        } catch {
            throw InstallError.fileSystem(
                "Could not copy skill to \(destination.path): \(error.localizedDescription)")
        }
    }

    private func symlink(_ link: URL, resolvesTo target: URL) -> Bool {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil else {
            return false
        }
        return fileManager.fileExists(atPath: target.path)
            && link.resolvingSymlinksInPath().path
                == target.resolvingSymlinksInPath().path
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
