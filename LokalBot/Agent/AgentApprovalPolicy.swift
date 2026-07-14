import Foundation

/// How the user scoped an approval from the transcript card.
enum ApprovalScope: Equatable {
    case once, session
}

/// Pure approval policy for gated agent tools. The bundled pi extension
/// raises approval requests for `write`, `edit`, `bash`, and any `read` whose
/// canonical path escapes the selected workspace. This type
/// decides whether a raised request can be answered automatically
/// (file-change toggle, session allowances) or must be shown to the user.
struct AgentApprovalPolicy: Equatable {
    var autoApproveFileChanges = false
    private(set) var sessionAllowedTools: Set<String> = []

    enum Verdict: Equatable { case allow, ask }

    func verdict(
        tool: String,
        path: String?,
        requestWorkspace: String?,
        selectedWorkspace: URL
    ) -> Verdict {
        // A read approval is only raised when pi's canonical path escapes the
        // selected workspace. Bash can read or transmit arbitrary user files.
        // Outside/malformed writes are privacy boundaries too. Only a canonical
        // write/edit path inside the process's selected workspace may inherit a
        // file-change toggle or a prior per-tool session allowance.
        guard Self.canPersistApproval(
            tool: tool,
            path: path,
            requestWorkspace: requestWorkspace,
            selectedWorkspace: selectedWorkspace) else { return .ask }
        if autoApproveFileChanges { return .allow }
        if sessionAllowedTools.contains(tool.lowercased()) { return .allow }
        return .ask
    }

    mutating func allowForSession(
        tool: String,
        path: String?,
        requestWorkspace: String?,
        selectedWorkspace: URL
    ) {
        guard Self.canPersistApproval(
            tool: tool,
            path: path,
            requestWorkspace: requestWorkspace,
            selectedWorkspace: selectedWorkspace) else { return }
        sessionAllowedTools.insert(tool.lowercased())
    }

    static func requiresExplicitPerRequestApproval(tool: String) -> Bool {
        tool.lowercased() == "read" || tool.lowercased() == "bash"
    }

    static func canPersistApproval(
        tool: String,
        path: String?,
        requestWorkspace: String?,
        selectedWorkspace: URL
    ) -> Bool {
        guard isFileChange(tool: tool),
              let path,
              let requestWorkspace,
              let requestedRoot = canonicalFileURL(URL(fileURLWithPath: requestWorkspace)),
              let selectedRoot = canonicalFileURL(selectedWorkspace),
              requestedRoot.path == selectedRoot.path,
              let requestedFile = canonicalFileURL(URL(fileURLWithPath: path)) else {
            return false
        }
        let rootComponents = selectedRoot.pathComponents
        let fileComponents = requestedFile.pathComponents
        return fileComponents.count >= rootComponents.count
            && Array(fileComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func isFileChange(tool: String) -> Bool {
        tool.lowercased() == "write" || tool.lowercased() == "edit"
    }

    /// Resolve symlinks through the nearest existing ancestor, then append any
    /// not-yet-created suffix. This matches the bundled extension's path rule
    /// and prevents a symlinked parent from turning an apparently local write
    /// into an external one.
    private static func canonicalFileURL(_ url: URL) -> URL? {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return nil }
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor = parent
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in suffix {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    mutating func resetSession() {
        sessionAllowedTools.removeAll()
    }
}
