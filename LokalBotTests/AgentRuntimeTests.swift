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
        try Data("{}".utf8).write(to: root.appendingPathComponent("pi/package.json"))
        try Data("lock".utf8).write(to: root.appendingPathComponent("pi/bun.lock"))
        let importedModule = cli.deletingLastPathComponent().appendingPathComponent("main.js")
        try Data("// imported runtime code".utf8).write(to: importedModule)
        let manifest = AgentRuntimeManifest(bun: AgentRuntimeArtifact(
            name: "test", url: URL(fileURLWithPath: "/test.zip"),
            sha256: String(repeating: "a", count: 64), archiveKind: .zip))
        let marker = AgentRuntimeVersionMarker(
            bunVersion: AgentRuntimeManifest.bunVersion,
            piVersion: AgentRuntimeManifest.piVersion,
            bunArchiveSHA256: manifest.bun.sha256,
            bunBinarySHA256: try SHA256Verifier.hexDigest(of: bun),
            piCLISHA256: try SHA256Verifier.hexDigest(of: cli),
            packageJSONSHA256: try SHA256Verifier.hexDigest(
                of: root.appendingPathComponent("pi/package.json")),
            lockfileSHA256: try SHA256Verifier.hexDigest(
                of: root.appendingPathComponent("pi/bun.lock")),
            piRuntimeTreeSHA256: try SHA256Verifier.treeHexDigest(
                of: root.appendingPathComponent("pi", isDirectory: true)))
        try JSONEncoder().encode(marker).write(
            to: AgentRuntimeLayout.versionMarker(under: root))
        XCTAssertTrue(AgentRuntimeLayout.isInstalled(under: root, manifest: manifest))

        // cli.js is unchanged: imported/runtime dependency code must be covered
        // by the whole-tree digest too.
        try Data("// tampered imported code".utf8).write(to: importedModule)
        XCTAssertFalse(AgentRuntimeLayout.isInstalled(under: root, manifest: manifest))
    }

    func testTreeDigestIsDeterministicAndCoversSymlinksAndHiddenFiles() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-digest-\(UUID().uuidString)", isDirectory: true)
        let first = parent.appendingPathComponent("first", isDirectory: true)
        let second = parent.appendingPathComponent("second", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        func populate(_ root: URL, reverseCreationOrder: Bool) throws {
            let package = root.appendingPathComponent("node_modules/pkg", isDirectory: true)
            let bin = root.appendingPathComponent("node_modules/.bin", isDirectory: true)
            let directories = reverseCreationOrder ? [bin, package] : [package, bin]
            for directory in directories {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try Data("export default 1".utf8).write(
                to: package.appendingPathComponent("main.js"))
            try Data("hidden".utf8).write(
                to: package.appendingPathComponent(".metadata"))
            try FileManager.default.createSymbolicLink(
                atPath: bin.appendingPathComponent("pkg").path,
                withDestinationPath: "../pkg/main.js")
        }

        try populate(first, reverseCreationOrder: false)
        try populate(second, reverseCreationOrder: true)
        let firstDigest = try SHA256Verifier.treeHexDigest(of: first)
        XCTAssertEqual(firstDigest, try SHA256Verifier.treeHexDigest(of: second))

        try FileManager.default.removeItem(
            at: second.appendingPathComponent("node_modules/.bin/pkg"))
        try FileManager.default.createSymbolicLink(
            atPath: second.appendingPathComponent("node_modules/.bin/pkg").path,
            withDestinationPath: "../pkg/.metadata")
        XCTAssertNotEqual(firstDigest, try SHA256Verifier.treeHexDigest(of: second))
    }

    func testManifestPinsExpectedVersions() {
        let manifest = AgentRuntimeManifest.current
        XCTAssertEqual(AgentRuntimeManifest.bunVersion, "1.3.14")
        XCTAssertEqual(AgentRuntimeManifest.piVersion, "0.80.3")
        XCTAssertTrue(manifest.bun.url.absoluteString.contains("bun-v1.3.14/bun-darwin-aarch64.zip"))
        XCTAssertEqual(manifest.bun.sha256.count, 64)
        XCTAssertEqual(manifest.bun.archiveKind, .zip)
        XCTAssertEqual(manifest.piRuntimeTreeSHA256?.count, 64)
        XCTAssertNotEqual(manifest.piRuntimeTreeSHA256, String(repeating: "0", count: 64))
    }

    /// Maintainers can point this at a fresh frozen-lockfile install when
    /// updating the pinned pi runtime. It deliberately skips in ordinary CI,
    /// which must not depend on npm or a preinstalled package tree.
    func testCurrentManifestMatchesProvidedPinnedRuntimeTree() throws {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_PINNED_RUNTIME_TREE"],
              !path.isEmpty else {
            throw XCTSkip("Set LOKALBOT_PINNED_RUNTIME_TREE to verify a fresh pinned install")
        }
        let digest = try SHA256Verifier.treeHexDigest(
            of: URL(fileURLWithPath: path, isDirectory: true))
        XCTAssertEqual(digest, AgentRuntimeManifest.current.piRuntimeTreeSHA256)
    }
}
