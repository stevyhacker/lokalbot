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

    private func makeRuntimeTemplate() throws -> URL {
        let template = sandbox.appendingPathComponent("runtime-template", isDirectory: true)
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: template.appendingPathComponent("package.json"))
        try Data("lockfileVersion = 1".utf8).write(to: template.appendingPathComponent("bun.lock"))
        return template
    }

    private var fakePackageInstaller: AgentRuntimeInstaller.PackageInstaller {
        { _, _, destination in
            let cliDir = destination.appendingPathComponent(
                "node_modules/@earendil-works/pi-coding-agent/dist", isDirectory: true)
            try FileManager.default.createDirectory(at: cliDir, withIntermediateDirectories: true)
            try Data("// cli".utf8).write(to: cliDir.appendingPathComponent("cli.js"))
        }
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

    private func manifest(bunZip: URL, corruptBunSHA: Bool = false) throws -> AgentRuntimeManifest {
        AgentRuntimeManifest(
            bun: AgentRuntimeArtifact(
                name: "Bun test", url: bunZip,
                sha256: corruptBunSHA ? String(repeating: "0", count: 64)
                                      : try SHA256Verifier.hexDigest(of: bunZip),
                archiveKind: .zip))
    }

    func testInstallsVerifiedArtifactsIntoLayout() async throws {
        let root = sandbox.appendingPathComponent("agent-runtime", isDirectory: true)
        let installer = AgentRuntimeInstaller(
            root: root,
            runtimeTemplate: try makeRuntimeTemplate(),
            packageInstaller: fakePackageInstaller)
        await installer.installIfNeeded(manifest: try manifest(bunZip: makeBunFixture()))
        XCTAssertEqual(installer.phase, .installed)
        XCTAssertTrue(AgentRuntimeLayout.isInstalled(under: root))
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: AgentRuntimeLayout.bunBinary(under: root).path))
        let markerData = try Data(contentsOf: AgentRuntimeLayout.versionMarker(under: root))
        let versions = try XCTUnwrap(
            JSONSerialization.jsonObject(with: markerData) as? [String: String])
        XCTAssertEqual(versions, ["bun": AgentRuntimeManifest.bunVersion,
                                  "pi": AgentRuntimeManifest.piVersion])
    }

    func testChecksumMismatchFailsAndInstallsNothing() async throws {
        let root = sandbox.appendingPathComponent("agent-runtime", isDirectory: true)
        let installer = AgentRuntimeInstaller(
            root: root,
            runtimeTemplate: try makeRuntimeTemplate(),
            packageInstaller: fakePackageInstaller)
        await installer.installIfNeeded(
            manifest: try manifest(bunZip: makeBunFixture(), corruptBunSHA: true))
        guard case .failed(let message) = installer.phase else {
            return XCTFail("expected failure, got \(installer.phase)")
        }
        XCTAssertTrue(message.contains("checksum"), message)
        XCTAssertFalse(AgentRuntimeLayout.isInstalled(under: root))
    }

    func testFrozenPackageInstallerCopiesManifestAndRunsExpectedCommand() async throws {
        let fakeBun = sandbox.appendingPathComponent("fake-bun")
        let script = """
        #!/bin/sh
        test "$1" = "install" || exit 11
        test "$2" = "--production" || exit 12
        test "$3" = "--frozen-lockfile" || exit 13
        test "$4" = "--ignore-scripts" || exit 14
        test -f package.json || exit 15
        test -f bun.lock || exit 16
        mkdir -p node_modules/@earendil-works/pi-coding-agent/dist
        touch node_modules/@earendil-works/pi-coding-agent/dist/cli.js
        """
        try Data(script.utf8).write(to: fakeBun)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: fakeBun.path)
        let destination = sandbox.appendingPathComponent("pi-destination", isDirectory: true)

        try await AgentRuntimeInstaller.installPackages(
            bun: fakeBun,
            template: makeRuntimeTemplate(),
            destination: destination)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("package.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("bun.lock").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(
            "node_modules/@earendil-works/pi-coding-agent/dist/cli.js").path))
    }

    func testAlreadyInstalledShortCircuits() async throws {
        let root = sandbox.appendingPathComponent("agent-runtime", isDirectory: true)
        let installer = AgentRuntimeInstaller(
            root: root,
            runtimeTemplate: try makeRuntimeTemplate(),
            packageInstaller: fakePackageInstaller)
        await installer.installIfNeeded(manifest: try manifest(bunZip: makeBunFixture()))
        XCTAssertEqual(installer.phase, .installed)
        // Second call must short-circuit without downloading: this manifest
        // points at nonexistent files, so any fetch attempt would fail.
        let bogus = AgentRuntimeManifest(
            bun: AgentRuntimeArtifact(name: "Bun", url: URL(fileURLWithPath: "/nonexistent.zip"),
                                      sha256: String(repeating: "0", count: 64), archiveKind: .zip))
        await installer.installIfNeeded(manifest: bogus)
        XCTAssertEqual(installer.phase, .installed)
    }
}
