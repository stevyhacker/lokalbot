import CryptoKit
import Foundation

enum AgentArchiveKind: Equatable {
    case zip, tarGz
}

struct AgentRuntimeArtifact: Equatable {
    let name: String
    let url: URL
    let sha256: String        // lowercase hex
    let archiveKind: AgentArchiveKind
}

/// Pinned runtime components for Agent Mode. Bun is downloaded as a
/// checksum-verified release archive. pi is installed from the public npm
/// registry using the frozen lockfile bundled with LokalBot.
struct AgentRuntimeManifest: Equatable {
    let bun: AgentRuntimeArtifact

    static let bunVersion = "1.3.14"
    static let piVersion = "0.80.3"

    static let current = AgentRuntimeManifest(
        bun: AgentRuntimeArtifact(
            name: "Bun \(bunVersion)",
            url: URL(string: "https://github.com/oven-sh/bun/releases/download/bun-v\(bunVersion)/bun-darwin-aarch64.zip")!,
            sha256: "d8b96221828ad6f97ac7ac0ab7e95872341af763001e8803e8267652c2652620",
            archiveKind: .zip))
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

    static func isInstalled(under root: URL = defaultRoot) -> Bool {
        FileManager.default.isExecutableFile(atPath: bunBinary(under: root).path)
            && FileManager.default.fileExists(atPath: piCLI(under: root).path)
    }

    /// Written at install time with the manifest's Bun and pi versions.
    /// Data for a future update path; `isInstalled` stays an existence check.
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
    /// Streaming digest so ~60 MB artifacts don't land in memory at once.
    static func hexDigest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
