import XCTest
@testable import LokalBot

@MainActor
final class AgentRuntimeInstallerTests: XCTestCase {

    private var sandbox: URL!

    override func setUp() async throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// zip containing bun-darwin-aarch64/bun (the layout of the real Bun release zip)
    private func makeBunFixture() throws -> URL {
        let stage = sandbox.appendingPathComponent("bun-stage/bun-darwin-aarch64", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho fake-bun\n".utf8).write(to: stage.appendingPathComponent("bun"))
        let zip = sandbox.appendingPathComponent("bun-darwin-aarch64.zip")
        try run("/usr/bin/zip", ["-qr", zip.path, "bun-darwin-aarch64"],
                cwd: stage.deletingLastPathComponent())
        return zip
    }

    /// tar.gz containing package.json + node_modules/.../dist/cli.js (the pi bundle layout)
    private func makePiFixture() throws -> URL {
        let stage = sandbox.appendingPathComponent("pi-stage", isDirectory: true)
        let cliDir = stage.appendingPathComponent("node_modules/@earendil-works/pi-coding-agent/dist", isDirectory: true)
        try FileManager.default.createDirectory(at: cliDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: stage.appendingPathComponent("package.json"))
        try Data("// cli".utf8).write(to: cliDir.appendingPathComponent("cli.js"))
        let tar = sandbox.appendingPathComponent("lokalbot-pi-bundle-test.tar.gz")
        try run("/usr/bin/tar", ["-czf", tar.path, "-C", stage.path, "package.json", "node_modules"], cwd: sandbox)
        return tar
    }

    private func run(_ tool: String, _ args: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = cwd
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) failed")
    }

    private func manifest(bunZip: URL, piTar: URL, corruptBunSHA: Bool = false) throws -> AgentRuntimeManifest {
        AgentRuntimeManifest(
            bun: AgentRuntimeArtifact(
                name: "Bun test", url: bunZip,
                sha256: corruptBunSHA ? String(repeating: "0", count: 64)
                                      : try SHA256Verifier.hexDigest(of: bunZip),
                archiveKind: .zip),
            piBundle: AgentRuntimeArtifact(
                name: "pi test", url: piTar,
                sha256: try SHA256Verifier.hexDigest(of: piTar),
                archiveKind: .tarGz))
    }

    func testInstallsVerifiedArtifactsIntoLayout() async throws {
        let root = sandbox.appendingPathComponent("agent-runtime", isDirectory: true)
        let installer = AgentRuntimeInstaller(root: root)
        await installer.installIfNeeded(manifest: try manifest(bunZip: makeBunFixture(), piTar: makePiFixture()))
        XCTAssertEqual(installer.phase, .installed)
        XCTAssertTrue(AgentRuntimeLayout.isInstalled(under: root))
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: AgentRuntimeLayout.bunBinary(under: root).path))
    }

    func testChecksumMismatchFailsAndInstallsNothing() async throws {
        let root = sandbox.appendingPathComponent("agent-runtime", isDirectory: true)
        let installer = AgentRuntimeInstaller(root: root)
        await installer.installIfNeeded(
            manifest: try manifest(bunZip: makeBunFixture(), piTar: makePiFixture(), corruptBunSHA: true))
        guard case .failed(let message) = installer.phase else {
            return XCTFail("expected failure, got \(installer.phase)")
        }
        XCTAssertTrue(message.contains("checksum"), message)
        XCTAssertFalse(AgentRuntimeLayout.isInstalled(under: root))
    }

    func testAlreadyInstalledShortCircuits() async throws {
        let root = sandbox.appendingPathComponent("agent-runtime", isDirectory: true)
        let installer = AgentRuntimeInstaller(root: root)
        await installer.installIfNeeded(manifest: try manifest(bunZip: makeBunFixture(), piTar: makePiFixture()))
        XCTAssertEqual(installer.phase, .installed)
        // Second call must short-circuit without downloading: this manifest
        // points at nonexistent files, so any fetch attempt would fail.
        let bogus = AgentRuntimeManifest(
            bun: AgentRuntimeArtifact(name: "Bun", url: URL(fileURLWithPath: "/nonexistent.zip"),
                                      sha256: String(repeating: "0", count: 64), archiveKind: .zip),
            piBundle: AgentRuntimeArtifact(name: "pi", url: URL(fileURLWithPath: "/nonexistent.tgz"),
                                           sha256: String(repeating: "0", count: 64), archiveKind: .tarGz))
        await installer.installIfNeeded(manifest: bogus)
        XCTAssertEqual(installer.phase, .installed)
    }
}
