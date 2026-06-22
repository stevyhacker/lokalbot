import Foundation
import os

private let logger = Logger(subsystem: AppIdentifiers.appBundleID, category: "CLIInstaller")

/// Installs (and uninstalls) the bundled `lokalbot-cli` + agent skill so a
/// user's coding agent (Claude Code, Codex, Cursor, Gemini, …) can read their
/// LokalBot library.
///
/// Symlink-based: the binary symlink points into the app bundle, so the CLI
/// auto-tracks every app update and always matches the on-disk schema.
/// "Installed" = both our binary and skill symlinks exist and resolve into
/// this app bundle. The CLI without its skill leaves agent access broken, so
/// we treat that state as "not installed" and re-offer the Install action.
///
/// Pattern ported from Seminarly's `SeminarlyCLIInstaller`, simplified to the
/// canonical skill path only (LokalBot does not also link `~/.claude/skills`).
struct LokalBotCLIInstaller {
    var home: URL
    /// The embedded CLI at `LokalBotV3.app/Contents/Helpers/lokalbot-cli`, nil
    /// when the bundle hasn't been built with CLI embedding enabled.
    var bundledBinary: URL?
    /// The embedded skill folder at `LokalBotV3.app/Contents/Resources/lokalbot-cli/`,
    /// nil when the SKILL.md asset wasn't copied in.
    var bundledSkillDir: URL?
    var fileManager: FileManager
    var environment: [String: String]

    /// Real installer, wired to the running app bundle and the user's home.
    static var bundled: LokalBotCLIInstaller {
        let fm = FileManager.default
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/lokalbot-cli")
        let skill = Bundle.main.resourceURL?.appending(path: "lokalbot-cli")
        return LokalBotCLIInstaller(
            home: fm.homeDirectoryForCurrentUser,
            bundledBinary: fm.fileExists(atPath: helper.path) ? helper : nil,
            bundledSkillDir: skill.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil },
            fileManager: fm,
            environment: ProcessInfo.processInfo.environment)
    }

    // MARK: - Paths we own

    /// Binary symlink so the bare `lokalbot-cli` name in SKILL.md resolves via $PATH.
    var binLink: URL { home.appending(path: ".local/bin/lokalbot-cli") }
    /// Canonical Open Skill path read by Codex / Gemini / Cursor / Claude
    /// Code (which now also looks here in addition to `~/.claude/skills/`).
    var skillLink: URL { home.appending(path: ".agents/skills/lokalbot-cli") }

    /// The single line we'd add to `~/.zshrc` if the user opts into PATH editing.
    static let pathExportLine = #"export PATH="$HOME/.local/bin:$PATH""#

    var touchedPaths: [String] { ["~/.local/bin/lokalbot-cli", "~/.agents/skills/lokalbot-cli"] }

    // MARK: - State

    /// True only when both the binary and the skill symlink resolve into the
    /// running app bundle. A half-install (one link missing, or pointing at a
    /// stale `LokalBotV3.app` copy) reads as "not installed" so the UI re-offers
    /// the Install action instead of hiding a broken state.
    var isInstalled: Bool {
        guard let binary = bundledBinary, let skill = bundledSkillDir else { return false }
        return symlink(binLink, resolvesTo: binary)
            && symlink(skillLink, resolvesTo: skill)
    }

    /// Refuses to install while the app is launched from a translocated copy
    /// (Gatekeeper randomised path) or a mounted read-only DMG — symlinking
    /// into those would dangle the moment the user ejects or moves the app.
    var isBundleLocationStable: Bool {
        guard let binary = bundledBinary else { return false }
        if binary.path.contains("/AppTranslocation/") { return false }
        let bundle = binary
            .deletingLastPathComponent()  // …/Contents/Helpers
            .deletingLastPathComponent()  // …/Contents
            .deletingLastPathComponent()  // …/LokalBotV3.app
        if let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true { return false }
        return true
    }

    /// True if any known coding-agent config directory exists under home —
    /// gates the empty-state offer ("Install for your coding agent?") so it
    /// only appears when the user actually runs one.
    static let agentConfigDirNames = [".claude", ".codex", ".cursor", ".gemini", ".agents"]
    var hasAgentConfigDir: Bool {
        Self.agentConfigDirNames.contains { isExistingDirectory(home.appending(path: $0)) }
    }

    /// Is `~/.local/bin` already on `$PATH`?
    var localBinOnPath: Bool {
        let path = environment["PATH"] ?? ""
        let candidate = "\(home.path)/.local/bin"
        return path.split(separator: ":").contains(where: { $0 == candidate })
    }

    // MARK: - Operations

    enum InstallError: LocalizedError {
        case bundleNotShipped
        case bundleNotStable
        case fileSystem(String)

        var errorDescription: String? {
            switch self {
            case .bundleNotShipped:
                return "This build doesn't ship the lokalbot-cli — install the latest release."
            case .bundleNotStable:
                return "The app is running from a translocated or read-only location. Move LokalBotV3.app to /Applications and relaunch."
            case .fileSystem(let message):
                return message
            }
        }
    }

    /// Place the symlinks. Idempotent: existing symlinks pointing at this
    /// bundle are left alone; symlinks pointing elsewhere are replaced.
    func install() throws {
        guard let binary = bundledBinary, let skill = bundledSkillDir else {
            throw InstallError.bundleNotShipped
        }
        guard isBundleLocationStable else { throw InstallError.bundleNotStable }

        try ensureDirectory(binLink.deletingLastPathComponent())
        try ensureDirectory(skillLink.deletingLastPathComponent())
        try replaceSymlink(at: binLink, target: binary)
        try replaceSymlink(at: skillLink, target: skill)
        logger.info("CLI installed at \(binLink.path) -> \(binary.path)")
    }

    /// Remove our symlinks if (and only if) they still point into this bundle.
    /// Leaves alien links alone so we never delete something we didn't create.
    func uninstall() throws {
        for link in [binLink, skillLink] {
            guard let destPath = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
                continue
            }
            // Only remove links that resolve into *some* LokalBotV3.app — never
            // foreign symlinks at our canonical paths.
            if destPath.contains("LokalBotV3.app/") {
                try fileManager.removeItem(at: link)
            }
        }
        logger.info("CLI uninstalled")
    }

    /// Append the PATH-export line to `~/.zshrc` if it isn't already present.
    func addLocalBinToPath() throws {
        let zshrc = home.appending(path: ".zshrc")
        let existing = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        guard !existing.contains(Self.pathExportLine) else { return }
        var updated = existing
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
        updated += "\n# Added by LokalBotV3 / lokalbot-cli\n\(Self.pathExportLine)\n"
        do {
            try updated.write(to: zshrc, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.fileSystem("Could not write to ~/.zshrc: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func ensureDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw InstallError.fileSystem("Could not create \(url.path): \(error.localizedDescription)")
        }
    }

    private func replaceSymlink(at link: URL, target: URL) throws {
        // Idempotency: if the link already resolves to `target`, leave it alone.
        if symlink(link, resolvesTo: target) { return }
        if fileManager.fileExists(atPath: link.path) {
            try fileManager.removeItem(at: link)
        }
        do {
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        } catch {
            throw InstallError.fileSystem("Could not create symlink at \(link.path): \(error.localizedDescription)")
        }
    }

    private func symlink(_ link: URL, resolvesTo target: URL) -> Bool {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil else { return false }
        return fileManager.fileExists(atPath: target.path)
            && link.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
