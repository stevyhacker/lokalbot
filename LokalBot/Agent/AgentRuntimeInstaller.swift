import Foundation

/// Downloads, verifies, and installs the Agent Mode runtime (Bun + the pi
/// bundle) into `AgentRuntimeLayout`. Both artifacts are pinned by SHA256
/// in `AgentRuntimeManifest.current`; a mismatch aborts the install — no
/// unverified code ever lands on disk. Assembly happens in a staging
/// directory that is swapped into place at the end, so a failed install
/// leaves nothing half-written.
@MainActor
final class AgentRuntimeInstaller: ObservableObject {

    enum Phase: Equatable {
        case idle
        case downloading(name: String, progress: Double)   // 0…1; -1 when length unknown
        case installing(name: String)
        case installed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let root: URL
    private let session: URLSession

    init(root: URL = AgentRuntimeLayout.defaultRoot, session: URLSession = .shared) {
        self.root = root
        self.session = session
        if AgentRuntimeLayout.isInstalled(under: root) { phase = .installed }
    }

    func installIfNeeded(manifest: AgentRuntimeManifest = .current) async {
        guard !AgentRuntimeLayout.isInstalled(under: root) else {
            phase = .installed
            return
        }
        let staging = root.deletingLastPathComponent()
            .appendingPathComponent("agent-runtime.staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            let bunArchive = try await download(manifest.bun, into: staging)
            let piArchive = try await download(manifest.piBundle, into: staging)

            phase = .installing(name: manifest.bun.name)
            let bunStage = staging.appendingPathComponent("bun-extract", isDirectory: true)
            try Self.unpack(bunArchive, kind: manifest.bun.archiveKind, into: bunStage)
            let bunBinary = bunStage.appendingPathComponent("bun-darwin-aarch64/bun")
            guard FileManager.default.fileExists(atPath: bunBinary.path) else {
                throw InstallError.layout("bun binary missing from archive")
            }

            phase = .installing(name: manifest.piBundle.name)
            let piStage = staging.appendingPathComponent("pi-extract", isDirectory: true)
            try Self.unpack(piArchive, kind: manifest.piBundle.archiveKind, into: piStage)
            let stagedCLI = piStage.appendingPathComponent(
                "node_modules/@earendil-works/pi-coding-agent/dist/cli.js")
            guard FileManager.default.fileExists(atPath: stagedCLI.path) else {
                throw InstallError.layout("pi cli.js missing from bundle")
            }

            let assembled = staging.appendingPathComponent("agent-runtime", isDirectory: true)
            try FileManager.default.createDirectory(
                at: assembled.appendingPathComponent("bun", isDirectory: true),
                withIntermediateDirectories: true)
            let installedBun = assembled.appendingPathComponent("bun/bun")
            try FileManager.default.moveItem(at: bunBinary, to: installedBun)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedBun.path)
            try FileManager.default.moveItem(at: piStage, to: assembled.appendingPathComponent("pi"))

            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: assembled, to: root)
            phase = .installed
        } catch {
            phase = .failed(Self.userMessage(for: error))
        }
    }

    // MARK: - Download + verify

    private func download(_ artifact: AgentRuntimeArtifact, into staging: URL) async throws -> URL {
        phase = .downloading(name: artifact.name, progress: 0)
        let destination = staging.appendingPathComponent(artifact.url.lastPathComponent)
        let (bytes, response) = try await session.bytes(from: artifact.url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw InstallError.download(artifact.name, "HTTP \(http.statusCode)")
        }
        let expected = response.expectedContentLength
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var received: Int64 = 0
        var chunk = Data()
        chunk.reserveCapacity(1 << 16)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 1 << 16 {
                try handle.write(contentsOf: chunk)
                received += Int64(chunk.count)
                chunk.removeAll(keepingCapacity: true)
                phase = .downloading(name: artifact.name,
                                     progress: expected > 0 ? Double(received) / Double(expected) : -1)
            }
        }
        try handle.write(contentsOf: chunk)
        try handle.close()

        guard try SHA256Verifier.hexDigest(of: destination) == artifact.sha256 else {
            throw InstallError.checksum(artifact.name)
        }
        return destination
    }

    // MARK: - Unpack

    static func unpack(_ archive: URL, kind: AgentArchiveKind, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        switch kind {
        case .zip:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", archive.path, "-d", directory.path]
        case .tarGz:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archive.path, "-C", directory.path]
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.unpack(archive.lastPathComponent, process.terminationStatus)
        }
    }

    // MARK: - Errors

    enum InstallError: Error {
        case download(String, String)
        case checksum(String)
        case unpack(String, Int32)
        case layout(String)
    }

    private static func userMessage(for error: Error) -> String {
        switch error {
        case InstallError.download(let name, let detail):
            return "Couldn't download \(name) (\(detail)). Check your connection and try again."
        case InstallError.checksum(let name):
            return "The downloaded \(name) failed its checksum and was discarded. Try again; if it keeps failing, the release may have been tampered with."
        case InstallError.unpack(let file, let code):
            return "Couldn't unpack \(file) (exit \(code))."
        case InstallError.layout(let detail):
            return "The downloaded archive didn't have the expected layout: \(detail)."
        default:
            return "Setup failed: \(error.localizedDescription)"
        }
    }
}
