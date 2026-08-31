import Foundation

/// Reads the enclosing app bundle's version for the MCP server handshake.
enum HelperVersion {
    private struct BundleInfo: Decodable {
        let version: String

        enum CodingKeys: String, CodingKey {
            case version = "CFBundleShortVersionString"
        }
    }

    static func current(binaryPath: String = CommandLine.arguments[0]) -> String {
        let binary = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath()
        let contents = binary
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let version = try? PropertyListDecoder().decode(
                BundleInfo.self,
                from: data).version else {
            return "dev"
        }
        return version
    }
}
