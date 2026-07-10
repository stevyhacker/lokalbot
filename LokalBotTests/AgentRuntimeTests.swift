import XCTest
@testable import LokalBot

final class AgentRuntimeTests: XCTestCase {

    func testSHA256HexDigestOfKnownData() throws {
        // shasum -a 256 <<< "hello" (with trailing newline stripped): sha256("hello")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha-test-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try SHA256Verifier.hexDigest(of: url),
                       "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    func testLayoutPaths() {
        let root = URL(fileURLWithPath: "/tmp/agent-runtime")
        XCTAssertEqual(AgentRuntimeLayout.bunBinary(under: root).path, "/tmp/agent-runtime/bun/bun")
        XCTAssertEqual(AgentRuntimeLayout.piCLI(under: root).path,
                       "/tmp/agent-runtime/pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js")
    }

    func testDefaultRootLivesInApplicationSupport() {
        XCTAssertEqual(AgentRuntimeLayout.defaultRoot,
                       AppDirectories.applicationSupport.appendingPathComponent("agent-runtime", isDirectory: true))
    }

    func testIsInstalledRequiresExecutableBunAndCLI() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(AgentRuntimeLayout.isInstalled(under: root))

        let bun = AgentRuntimeLayout.bunBinary(under: root)
        let cli = AgentRuntimeLayout.piCLI(under: root)
        try FileManager.default.createDirectory(at: bun.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bun)
        try Data("// cli".utf8).write(to: cli)
        XCTAssertFalse(AgentRuntimeLayout.isInstalled(under: root), "bun not yet executable")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bun.path)
        XCTAssertTrue(AgentRuntimeLayout.isInstalled(under: root))
    }

    func testManifestPinsExpectedVersions() {
        let manifest = AgentRuntimeManifest.current
        XCTAssertEqual(AgentRuntimeManifest.bunVersion, "1.3.14")
        XCTAssertEqual(AgentRuntimeManifest.piVersion, "0.80.3")
        XCTAssertTrue(manifest.bun.url.absoluteString.contains("bun-v1.3.14/bun-darwin-aarch64.zip"))
        XCTAssertEqual(manifest.bun.sha256.count, 64)
        XCTAssertEqual(manifest.bun.archiveKind, .zip)
    }
}
