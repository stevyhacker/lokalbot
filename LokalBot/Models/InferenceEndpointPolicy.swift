import Foundation

/// Makes the local/remote boundary explicit for user-configured inference
/// servers. Loopback endpoints stay zero-friction; any other host must be
/// approved before transcripts, screen text, or agent context can be sent.
enum InferenceEndpointPolicy {

    enum PolicyError: LocalizedError, Equatable {
        case unsupportedURL
        case remoteApprovalRequired(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedURL:
                "Use an http or https inference-server URL."
            case .remoteApprovalRequired(let origin):
                "Approve the remote inference server \(origin) under Settings → Models before sending meeting or workday text to it."
            }
        }
    }

    static func origin(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        // URLComponents.host rejects a bare IPv6 literal even though URL.host
        // correctly returns one (for example, "::1"). Render the authority
        // directly so loopback and approved remote IPv6 origins stay canonical.
        let authority = host.contains(":") ? "[\(host)]" : host
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(authority)\(port)"
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "::1"
            || host == "0:0:0:0:0:0:0:1"
            || host == "0.0.0.0"
            || host == "127.0.0.1"
            || host.hasPrefix("127.")
    }

    static func requiresApproval(_ url: URL) -> Bool {
        origin(for: url) != nil && !isLoopback(url)
    }

    static func isAllowed(_ url: URL, approvedOrigins: [String]) -> Bool {
        guard let origin = origin(for: url) else { return false }
        return isLoopback(url) || approvedOrigins.contains(origin)
    }

    static func validate(_ url: URL, approvedOrigins: [String]) throws {
        guard let origin = origin(for: url) else { throw PolicyError.unsupportedURL }
        guard isLoopback(url) || approvedOrigins.contains(origin) else {
            throw PolicyError.remoteApprovalRequired(origin)
        }
    }
}
