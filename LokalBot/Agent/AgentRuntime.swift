import CryptoKit
import Foundation

enum AgentArchiveKind: Equatable, Sendable {
    case zip, tarGz
}

struct AgentRuntimeArtifact: Equatable, Sendable {
    let name: String
    let url: URL
    let sha256: String        // lowercase hex
    let archiveKind: AgentArchiveKind
}

/// Pinned runtime components for Agent Mode. Bun is downloaded as a
/// checksum-verified release archive. pi is installed from the public npm
/// registry using the frozen lockfile bundled with LokalBot.
struct AgentRuntimeManifest: Equatable, Sendable {
    let bun: AgentRuntimeArtifact
    let bunBinarySHA256: String?
    let piCLISHA256: String?
    let packageJSONSHA256: String?
    let lockfileSHA256: String?
    let piRuntimeTreeSHA256: String?

    init(bun: AgentRuntimeArtifact,
         bunBinarySHA256: String? = nil,
         piCLISHA256: String? = nil,
         packageJSONSHA256: String? = nil,
         lockfileSHA256: String? = nil,
         piRuntimeTreeSHA256: String? = nil) {
        self.bun = bun
        self.bunBinarySHA256 = bunBinarySHA256
        self.piCLISHA256 = piCLISHA256
        self.packageJSONSHA256 = packageJSONSHA256
        self.lockfileSHA256 = lockfileSHA256
        self.piRuntimeTreeSHA256 = piRuntimeTreeSHA256
    }

    static let bunVersion = "1.3.14"
    static let piVersion = "0.80.3"

    static let current = AgentRuntimeManifest(
        bun: AgentRuntimeArtifact(
            name: "Bun \(bunVersion)",
            url: URL(string: "https://github.com/oven-sh/bun/releases/download/bun-v\(bunVersion)/bun-darwin-aarch64.zip")!,
            sha256: "d8b96221828ad6f97ac7ac0ab7e95872341af763001e8803e8267652c2652620",
            archiveKind: .zip),
        bunBinarySHA256: "e0c90ec15d33363e6b70713d56bc3b2c7585c17f40a0fe0f8fd9305901d4e233",
        piCLISHA256: "af302f231437eaf6f37691bce4b34234fcb626bcb5eb3910d4fc3f6519bf78ca",
        packageJSONSHA256: "de26644ce5bd02d5ab06da79f2c52bb14a1a9ffb2741d6f5b1dbc7fe31c04d51",
        lockfileSHA256: "2015685bbfa61c88d8351a5e9fb500edf51e605f1fa01102cd9a5a2925014147",
        piRuntimeTreeSHA256: "44db8e5fdb7ed4aadd24e8df4bf4a6bba4720175656d5ca6879a7e786a59e0de")
}

struct AgentRuntimeVersionMarker: Codable, Equatable {
    let bunVersion: String
    let piVersion: String
    let bunArchiveSHA256: String
    let bunBinarySHA256: String
    let piCLISHA256: String
    let packageJSONSHA256: String
    let lockfileSHA256: String
    let piRuntimeTreeSHA256: String
}

/// On-disk layout of the installed runtime. Lives in Application Support
/// (NOT the storage root) alongside model caches and the llama-server
/// binary — it's a machine-local cache, not user data.
enum AgentRuntimeLayout {

    static var defaultRoot: URL {
        AppDirectories.applicationSupport.appendingPathComponent("agent-runtime", isDirectory: true)
    }

    static func bunBinary(under root: URL) -> URL {
        root.appendingPathComponent("bun/bun")
    }

    static func piCLI(under root: URL) -> URL {
        root.appendingPathComponent("pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js")
    }

    /// Cheap receipt check for the normal launch path. Installation already
    /// verifies every staged byte before the atomic swap, so routine Agent Mode
    /// entry only needs to prove that the expected entry points and matching
    /// version receipt are present. Use `isIntegrityValid` for an explicit deep
    /// audit of the mutable runtime tree.
    static func isInstalled(under root: URL = defaultRoot,
                            manifest: AgentRuntimeManifest = .current) -> Bool {
        let bun = bunBinary(under: root)
        let cli = piCLI(under: root)
        let packageJSON = root.appendingPathComponent("pi/package.json")
        let lockfile = root.appendingPathComponent("pi/bun.lock")
        guard FileManager.default.isExecutableFile(atPath: bun.path),
              FileManager.default.fileExists(atPath: cli.path),
              FileManager.default.fileExists(atPath: packageJSON.path),
              FileManager.default.fileExists(atPath: lockfile.path),
              let data = try? Data(contentsOf: versionMarker(under: root)),
              let marker = try? JSONDecoder().decode(AgentRuntimeVersionMarker.self, from: data),
              marker.bunVersion == AgentRuntimeManifest.bunVersion,
              marker.piVersion == AgentRuntimeManifest.piVersion,
              marker.bunArchiveSHA256 == manifest.bun.sha256.lowercased(),
              digestReceipt(marker.bunBinarySHA256, matches: manifest.bunBinarySHA256),
              digestReceipt(marker.piCLISHA256, matches: manifest.piCLISHA256),
              digestReceipt(marker.packageJSONSHA256, matches: manifest.packageJSONSHA256),
              digestReceipt(marker.lockfileSHA256, matches: manifest.lockfileSHA256),
              digestReceipt(marker.piRuntimeTreeSHA256, matches: manifest.piRuntimeTreeSHA256) else {
            return false
        }
        return true
    }

    /// Explicit, recursive integrity audit. This intentionally opens every pi
    /// runtime file and is therefore reserved for installation, repair, tests,
    /// and user-requested verification rather than ordinary pane navigation.
    static func isIntegrityValid(under root: URL = defaultRoot,
                                 manifest: AgentRuntimeManifest = .current) -> Bool {
        guard isInstalled(under: root, manifest: manifest),
              let data = try? Data(contentsOf: versionMarker(under: root)),
              let marker = try? JSONDecoder().decode(AgentRuntimeVersionMarker.self, from: data)
        else { return false }

        let bun = bunBinary(under: root)
        let cli = piCLI(under: root)
        let packageJSON = root.appendingPathComponent("pi/package.json")
        let lockfile = root.appendingPathComponent("pi/bun.lock")
        let piRuntime = root.appendingPathComponent("pi", isDirectory: true)
        guard let bunDigest = try? SHA256Verifier.hexDigest(of: bun),
              let cliDigest = try? SHA256Verifier.hexDigest(of: cli),
              let packageDigest = try? SHA256Verifier.hexDigest(of: packageJSON),
              let lockDigest = try? SHA256Verifier.hexDigest(of: lockfile),
              let treeDigest = try? SHA256Verifier.treeHexDigest(of: piRuntime),
              bunDigest == marker.bunBinarySHA256,
              cliDigest == marker.piCLISHA256,
              packageDigest == marker.packageJSONSHA256,
              lockDigest == marker.lockfileSHA256,
              treeDigest == marker.piRuntimeTreeSHA256 else {
            return false
        }
        return true
    }

    private static func digestReceipt(_ receipt: String, matches expected: String?) -> Bool {
        guard receipt.count == 64,
              receipt.allSatisfy({ $0.isHexDigit }) else { return false }
        return expected.map { receipt == $0.lowercased() } ?? true
    }

    /// Written at install time with versions and verified artifact digests.
    static func versionMarker(under root: URL) -> URL {
        root.appendingPathComponent("version.json")
    }

    /// pi session JSONL trees live under the storage root so they follow
    /// LOKALBOT_STORAGE_ROOT (hermetic in e2e/UI tests) and land next to
    /// the rest of the user's library.
    static var sessionsDirectory: URL {
        AppDirectories.libraryRoot.appendingPathComponent("agent/sessions", isDirectory: true)
    }
}

enum SHA256Verifier {
    enum DigestError: Error {
        case notDirectory(String)
        case unsupportedTreeEntry(String)
    }

    /// Streaming digest so ~60 MB artifacts don't land in memory at once.
    static func hexDigest(of url: URL) throws -> String {
        try digest(of: url).map { String(format: "%02x", $0) }.joined()
    }

    /// Deterministic digest of a directory's complete shape and contents.
    /// Records are ordered by raw UTF-8 path, length-delimited, and tagged by
    /// file type. Symlinks hash their link text and are never followed; regular
    /// files hash their bytes. Directory records make empty/additional
    /// directories visible too. Metadata and absolute install paths are
    /// deliberately excluded so identical installs hash identically.
    static func treeHexDigest(of root: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DigestError.notDirectory(root.path)
        }

        var hasher = SHA256()
        try hashDirectory(root, relativePath: "", into: &hasher)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(of url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }

    private static func hashDirectory(
        _ directory: URL,
        relativePath: String,
        into hasher: inout SHA256
    ) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [])
            .sorted {
                $0.lastPathComponent.utf8.lexicographicallyPrecedes(
                    $1.lastPathComponent.utf8)
            }

        for entry in entries {
            let path = relativePath.isEmpty
                ? entry.lastPathComponent
                : "\(relativePath)/\(entry.lastPathComponent)"
            let values = try entry.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                let destination = try FileManager.default.destinationOfSymbolicLink(
                    atPath: entry.path)
                updateRecord(kind: 0x6C, path: path, payload: Data(destination.utf8), into: &hasher)
            } else if values.isDirectory == true {
                updateRecord(kind: 0x64, path: path, payload: Data(), into: &hasher)
                try hashDirectory(entry, relativePath: path, into: &hasher)
            } else if values.isRegularFile == true {
                updateRecord(
                    kind: 0x66,
                    path: path,
                    payload: Data(try digest(of: entry)),
                    into: &hasher)
            } else {
                throw DigestError.unsupportedTreeEntry(entry.path)
            }
        }
    }

    private static func updateRecord(
        kind: UInt8,
        path: String,
        payload: Data,
        into hasher: inout SHA256
    ) {
        hasher.update(data: Data([kind]))
        updateLengthPrefixed(Data(path.utf8), into: &hasher)
        updateLengthPrefixed(payload, into: &hasher)
    }

    private static func updateLengthPrefixed(_ data: Data, into hasher: inout SHA256) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            hasher.update(data: Data(bytes))
        }
        hasher.update(data: data)
    }
}
