import XCTest
@testable import LokalBot

final class AgentApprovalPolicyTests: XCTestCase {

    private let workspace = URL(fileURLWithPath: "/tmp/lokalbot-agent-policy-workspace")

    private func verdict(_ policy: AgentApprovalPolicy, tool: String, path: String? = nil,
                         requestWorkspace: String? = nil) -> AgentApprovalPolicy.Verdict {
        policy.verdict(
            tool: tool,
            path: path,
            requestWorkspace: requestWorkspace,
            selectedWorkspace: workspace)
    }

    func testGatedToolAsksByDefault() {
        let policy = AgentApprovalPolicy()
        XCTAssertEqual(verdict(policy, tool: "bash"), .ask)
        XCTAssertEqual(verdict(policy, tool: "write"), .ask)
        XCTAssertEqual(verdict(policy, tool: "edit"), .ask)
    }

    func testAutoApproveAllowsOnlyFileChanges() {
        var policy = AgentApprovalPolicy()
        policy.autoApproveFileChanges = true
        let root = workspace.path
        XCTAssertEqual(verdict(policy, tool: "bash", path: "\(root)/script.sh",
                               requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "write", path: "\(root)/note.txt",
                               requestWorkspace: root), .allow)
        XCTAssertEqual(verdict(policy, tool: "edit", path: "\(root)/nested/note.txt",
                               requestWorkspace: root), .allow)
        XCTAssertEqual(verdict(policy, tool: "unknown", path: "\(root)/note.txt",
                               requestWorkspace: root), .ask)
    }

    func testPrivacySensitiveToolsAlwaysAsk() {
        var policy = AgentApprovalPolicy()
        policy.autoApproveFileChanges = true
        let root = workspace.path
        policy.allowForSession(
            tool: "read", path: "/private/notes.txt", requestWorkspace: root,
            selectedWorkspace: workspace)
        policy.allowForSession(
            tool: "bash", path: nil, requestWorkspace: root,
            selectedWorkspace: workspace)
        XCTAssertEqual(verdict(policy, tool: "read", path: "/private/notes.txt",
                               requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "bash", requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "BASH", requestWorkspace: root), .ask)
    }

    func testSessionAllowanceIsPerTool() {
        var policy = AgentApprovalPolicy()
        let root = workspace.path
        policy.allowForSession(
            tool: "write", path: "\(root)/one.txt", requestWorkspace: root,
            selectedWorkspace: workspace)
        XCTAssertEqual(verdict(policy, tool: "write", path: "\(root)/two.txt",
                               requestWorkspace: root), .allow)
        XCTAssertEqual(verdict(policy, tool: "edit", path: "\(root)/two.txt",
                               requestWorkspace: root), .ask)
    }

    func testResetSessionClearsAllowances() {
        var policy = AgentApprovalPolicy()
        let root = workspace.path
        policy.allowForSession(
            tool: "write", path: "\(root)/one.txt", requestWorkspace: root,
            selectedWorkspace: workspace)
        policy.resetSession()
        XCTAssertEqual(verdict(policy, tool: "write", path: "\(root)/two.txt",
                               requestWorkspace: root), .ask)
    }

    func testResetSessionKeepsAutoApproveToggle() {
        var policy = AgentApprovalPolicy()
        policy.autoApproveFileChanges = true
        policy.resetSession()
        let root = workspace.path
        XCTAssertEqual(verdict(policy, tool: "write", path: "\(root)/note.txt",
                               requestWorkspace: root), .allow)
    }

    func testOutsideMissingAndMismatchedPathsNeverInheritApproval() {
        var policy = AgentApprovalPolicy()
        policy.autoApproveFileChanges = true
        let root = workspace.path
        XCTAssertEqual(verdict(policy, tool: "write", requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "write", path: "/private/outside.txt",
                               requestWorkspace: root), .ask)
        XCTAssertEqual(verdict(policy, tool: "edit", path: "\(root)/note.txt",
                               requestWorkspace: "/private/other-workspace"), .ask)
    }

    func testSymlinkEscapedWriteNeverInheritsApproval() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-policy-symlink-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape", isDirectory: true),
            withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: parent) }

        var policy = AgentApprovalPolicy()
        policy.autoApproveFileChanges = true
        XCTAssertEqual(
            policy.verdict(
                tool: "write",
                path: root.appendingPathComponent("escape/private.txt").path,
                requestWorkspace: root.path,
                selectedWorkspace: root),
            .ask)
    }
}
