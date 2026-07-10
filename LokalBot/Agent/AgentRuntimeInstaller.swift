import Foundation

/// Downloads and verifies Bun, then uses the frozen lockfile bundled with the
/// app to install pi from the public npm registry. Assembly happens in a
/// staging directory that is swapped into place at the end, so a failed setup
/// leaves nothing half-written.
@MainActor
final class AgentRuntimeInstaller: ObservableObject {

    typealias PackageInstaller = (_ bun: URL, _ template: URL, _ destination: URL) async throws -> Void

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
    private let runtimeTemplate: URL
    private let packageInstaller: PackageInstaller

    init(root: URL = AgentRuntimeLayout.defaultRoot,
         session: URLSession = .shared,
         runtimeTemplate: URL? = nil,
         packageInstaller: @escaping PackageInstaller = AgentRuntimeInstaller.installPackages) {
        self.root = root
        self.session = session
        self.runtimeTemplate = runtimeTemplate
            ?? Bundle.main.resourceURL?.appendingPathComponent("pi/runtime", isDirectory: true)
            ?? URL(fileURLWithPath: "pi/runtime", isDirectory: true)
        self.packageInstaller = packageInstaller
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

            phase = .installing(name: manifest.bun.name)
            let bunStage = staging.appendingPathComponent("bun-extract", isDirectory: true)
            try Self.unpack(bunArchive, kind: manifest.bun.archiveKind, into: bunStage)
            let bunBinary = bunStage.appendingPathComponent("bun-darwin-aarch64/bun")
            guard FileManager.default.fileExists(atPath: bunBinary.path) else {
                throw InstallError.layout("bun binary missing from archive")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: bunBinary.path)

            phase = .installing(name: "pi \(AgentRuntimeManifest.piVersion)")
            let piStage = staging.appendingPathComponent("pi-install", isDirectory: true)
            try await packageInstaller(bunBinary, runtimeTemplate, piStage)
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

            let marker = try JSONSerialization.data(
                withJSONObject: ["bun": AgentRuntimeManifest.bunVersion,
                                 "pi": AgentRuntimeManifest.piVersion],
                options: [.sortedKeys])
            try marker.write(to: AgentRuntimeLayout.versionMarker(under: assembled))

            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: assembled, to: root)
            phase = .installed
        } catch {
            phase = .failed(Self.userMessage(for: error))
        }
    }

    // MARK: - Frozen package install

    static func installPackages(bun: URL, template: URL, destination: URL) async throws {
        let packageJSON = template.appendingPathComponent("package.json")
        let lockfile = template.appendingPathComponent("bun.lock")
        guard FileManager.default.fileExists(atPath: packageJSON.path),
              FileManager.default.fileExists(atPath: lockfile.path) else {
            throw InstallError.layout("the bundled pi package manifest is missing")
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: packageJSON,
                                         to: destination.appendingPathComponent("package.json"))
        try FileManager.default.copyItem(at: lockfile,
                                         to: destination.appendingPathComponent("bun.lock"))

        let logURL = destination.appendingPathComponent("install.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer {
            try? log.close()
            try? FileManager.default.removeItem(at: logURL)
        }

        let process = Process()
        process.executableURL = bun
        process.arguments = ["install", "--production", "--frozen-lockfile", "--ignore-scripts"]
        process.currentDirectoryURL = destination
        process.standardOutput = log
        process.standardError = log

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        try log.synchronize()
        guard status == 0 else {
            let data = (try? Data(contentsOf: logURL)) ?? Data()
            let fullDetail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = fullDetail.map { String($0.suffix(2_000)) }
            throw InstallError.packageInstall(detail?.isEmpty == false ? detail! : "exit \(status)")
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

        guard try SHA256Verifier.hexDigest(of: destination).lowercased() == artifact.sha256.lowercased() else {
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
        case packageInstall(String)
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
            return "Agent setup couldn't find the expected files: \(detail)."
        case InstallError.packageInstall(let detail):
            return "Couldn't install pi from the public package registry. Check your connection and try again.\n\(detail)"
        default:
            return "Setup failed: \(error.localizedDescription)"
        }
    }
}
