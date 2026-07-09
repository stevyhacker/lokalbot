import XCTest
@testable import LokalBot

final class AgentApprovalPolicyTests: XCTestCase {

    func testGatedToolAsksByDefault() {
        let policy = AgentApprovalPolicy()
        XCTAssertEqual(policy.verdict(tool: "bash"), .ask)
        XCTAssertEqual(policy.verdict(tool: "write"), .ask)
        XCTAssertEqual(policy.verdict(tool: "edit"), .ask)
    }

    func testAutoApproveAllAllowsEverything() {
        var policy = AgentApprovalPolicy()
        policy.autoApproveAll = true
        XCTAssertEqual(policy.verdict(tool: "bash"), .allow)
    }

    func testSessionAllowanceIsPerTool() {
        var policy = AgentApprovalPolicy()
        policy.allowForSession(tool: "bash")
        XCTAssertEqual(policy.verdict(tool: "bash"), .allow)
        XCTAssertEqual(policy.verdict(tool: "write"), .ask)
    }

    func testResetSessionClearsAllowances() {
        var policy = AgentApprovalPolicy()
        policy.allowForSession(tool: "bash")
        policy.resetSession()
        XCTAssertEqual(policy.verdict(tool: "bash"), .ask)
    }

    func testResetSessionKeepsAutoApproveToggle() {
        var policy = AgentApprovalPolicy()
        policy.autoApproveAll = true
        policy.resetSession()
        XCTAssertEqual(policy.verdict(tool: "bash"), .allow)
    }
}
