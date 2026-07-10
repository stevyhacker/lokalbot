import Foundation

/// Everything needed to spawn one pi RPC subprocess.
struct PiLaunchPlan: Equatable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL
}

/// Builds the exact pi launch contract from the 2026-07-09 spec. pi is
/// fully isolated from the user's ~/.pi and any repo-local pi config
/// (--no-extensions/-e, --no-skills/--skill, --no-prompt-templates,
/// --no-approve) and fully offline (--offline + PI_SKIP_VERSION_CHECK —
/// pi ships install telemetry and update checks enabled by default).
/// --no-context-files is deliberately NOT passed: project AGENTS.md /
/// CLAUDE.md context stays on.
enum PiLaunchPlanner {

    static func plan(bun: URL,
                     piCLI: URL,
                     extensionDirectory: URL,
                     skillDirectory: URL?,
                     sessionDirectory: URL,
                     workspace: URL,
                     endpoint: AgentLLMEndpoint,
                     helpersDirectory: URL?,
                     baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> PiLaunchPlan {
        var arguments = [
            piCLI.path,
            "--mode", "rpc",
            "--provider", "lokalbot",
            "--model", endpoint.model,
            "--no-extensions", "-e", extensionDirectory.path,
            "--no-skills",
        ]
        if let skillDirectory {
            arguments += ["--skill", skillDirectory.path]
        }
        arguments += [
            "--no-prompt-templates",
            "--no-approve",
            "--session-dir", sessionDirectory.path,
            "--offline",
        ]

        var environment = baseEnvironment
        environment["LOKALBOT_LLM_BASE_URL"] = endpoint.baseURL.absoluteString
        environment["LOKALBOT_LLM_MODEL"] = endpoint.model
        environment["LOKALBOT_LLM_CTX"] = String(endpoint.contextTokens)
        if let apiKey = endpoint.apiKey {
            environment["LOKALBOT_LLM_API_KEY"] = apiKey
        }
        environment["PI_SKIP_VERSION_CHECK"] = "1"
        if let helpersDirectory {
            // lokalbot-cli lives in Contents/Helpers; the bundled skill
            // invokes it by name, so it must be on the agent's PATH.
            let existing = environment["PATH"] ?? ""
            environment["PATH"] = existing.isEmpty
                ? helpersDirectory.path
                : "\(helpersDirectory.path):\(existing)"
        }
        return PiLaunchPlan(executable: bun,
                            arguments: arguments,
                            environment: environment,
                            workingDirectory: workspace)
    }
}
