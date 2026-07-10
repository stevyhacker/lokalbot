import XCTest
@testable import LokalBot

final class PiLaunchPlannerTests: XCTestCase {

    private let endpoint = AgentLLMEndpoint(
        baseURL: URL(string: "http://127.0.0.1:17872/v1")!,
        model: "qwen2.5-7b-instruct",
        contextTokens: 16_384,
        apiKey: nil)

    private func makePlan(apiKey: String? = nil,
                          skill: URL? = URL(fileURLWithPath: "/app/Resources/pi/lokalbot-cli-skill"),
                          helpers: URL? = URL(fileURLWithPath: "/app/Contents/Helpers"),
                          continuePrevious: Bool = false) -> PiLaunchPlan {
        PiLaunchPlanner.plan(
            bun: URL(fileURLWithPath: "/rt/bun/bun"),
            piCLI: URL(fileURLWithPath: "/rt/pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"),
            extensionDirectory: URL(fileURLWithPath: "/app/Resources/pi/lokalbot-extension"),
            skillDirectory: skill,
            sessionDirectory: URL(fileURLWithPath: "/store/agent/sessions"),
            workspace: URL(fileURLWithPath: "/work"),
            endpoint: AgentLLMEndpoint(baseURL: endpoint.baseURL, model: endpoint.model,
                                       contextTokens: endpoint.contextTokens, apiKey: apiKey),
            helpersDirectory: helpers,
            continuePreviousSession: continuePrevious,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/x"])
    }

    func testArgumentsMatchTheSpecContract() {
        XCTAssertEqual(makePlan().arguments, [
            "/rt/pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js",
            "--mode", "rpc",
            "--provider", "lokalbot",
            "--model", "qwen2.5-7b-instruct",
            "--no-extensions", "-e", "/app/Resources/pi/lokalbot-extension",
            "--no-skills", "--skill", "/app/Resources/pi/lokalbot-cli-skill",
            "--no-prompt-templates",
            "--no-approve",
            "--session-dir", "/store/agent/sessions",
            "--offline",
        ])
    }

    func testEnvironmentCarriesEndpointAndPrivacyGuards() {
        let env = makePlan().environment
        XCTAssertEqual(env["LOKALBOT_LLM_BASE_URL"], "http://127.0.0.1:17872/v1")
        XCTAssertEqual(env["LOKALBOT_LLM_MODEL"], "qwen2.5-7b-instruct")
        XCTAssertEqual(env["LOKALBOT_LLM_CTX"], "16384")
        XCTAssertNil(env["LOKALBOT_LLM_API_KEY"])
        XCTAssertEqual(env["PI_SKIP_VERSION_CHECK"], "1")
        XCTAssertEqual(env["PI_TELEMETRY"], "0")
        XCTAssertEqual(env["PI_CODING_AGENT_DIR"], "/store/agent/pi-config")
        XCTAssertEqual(env["PATH"], "/app/Contents/Helpers:/usr/bin:/bin")
        XCTAssertEqual(env["HOME"], "/Users/x", "base environment is preserved")
    }

    func testAPIKeyIsPassedWhenPresent() {
        XCTAssertEqual(makePlan(apiKey: "sk-test").environment["LOKALBOT_LLM_API_KEY"], "sk-test")
    }

    func testNoSkillDirectoryOmitsSkillFlagButKeepsNoSkills() {
        let arguments = makePlan(skill: nil).arguments
        XCTAssertTrue(arguments.contains("--no-skills"))
        XCTAssertFalse(arguments.contains("--skill"))
    }

    func testExecutableAndCwd() {
        let plan = makePlan()
        XCTAssertEqual(plan.executable.path, "/rt/bun/bun")
        XCTAssertEqual(plan.workingDirectory.path, "/work")
    }

    func testNoContextFilesFlagIsDeliberatelyAbsent() {
        XCTAssertFalse(makePlan().arguments.contains("--no-context-files"),
                       "project AGENTS.md/CLAUDE.md context stays enabled by design")
    }

    func testContinueFlagOnlyAppearsForResumeLaunches() {
        XCTAssertFalse(makePlan().arguments.contains("--continue"))
        XCTAssertTrue(makePlan(continuePrevious: true).arguments.contains("--continue"))
    }
}
