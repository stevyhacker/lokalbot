import XCTest
@testable import LokalBot

/// Pure-logic coverage for the llama-server lifecycle owner. Booting the real
/// subprocess belongs to e2e; these tests pin the invariants the rest of the
/// app builds on: loopback-only base URLs, the three distinct roles/ports, and
/// the /v1/models response parsing that health checks depend on.
final class LlamaServerTests: XCTestCase {

    /// The privacy story requires every built-in server to be reachable only
    /// via loopback. A non-loopback base URL here would be a data-exfiltration
    /// bug, not a configuration choice.
    func testSharedServersAreLoopbackOnlyAndOnDistinctPorts() {
        let servers: [(LlamaServer, Int)] = [
            (.shared, 17872), (.embedder, 17873), (.cotyping, 17874),
        ]
        for (server, port) in servers {
            XCTAssertEqual(server.port, port)
            XCTAssertEqual(server.baseURL.host, "127.0.0.1")
            XCTAssertEqual(server.baseURL.port, port)
        }
        XCTAssertEqual(Set(servers.map(\.1)).count, 3, "roles must not share a port")
    }

    func testServedModelNamesParsesBothLlamaServerShapes() throws {
        let payload = Data("""
        {"models":[{"name":"qwen.gguf","model":"/models/qwen.gguf"}],
         "data":[{"id":"lfm.gguf"},{"id":""}]}
        """.utf8)

        let names = LlamaServer.servedModelNames(from: payload)

        XCTAssertEqual(names, ["qwen.gguf", "/models/qwen.gguf", "lfm.gguf"])
    }

    func testServedModelNamesIsEmptyForMalformedPayload() {
        XCTAssertEqual(LlamaServer.servedModelNames(from: Data("not json".utf8)), [])
        XCTAssertEqual(LlamaServer.servedModelNames(from: Data("{}".utf8)), [])
    }

    func testModelMatchKeyUsesFileName() {
        let url = URL(fileURLWithPath: "/tmp/models/qwen3.5-4b-q4.gguf")
        XCTAssertEqual(LlamaServer.modelMatchKey(for: url), "qwen3.5-4b-q4.gguf")
    }

    func testAuthenticationTokenIsStableAndHighEntropy() async {
        // A private instance on an unused port: the token path is derived from
        // the port, so this never touches the three production token files.
        // The persisted token file is removed on both ends of the test.
        let port = 59_871
        let tokenFile = AppDirectories.applicationSupport
            .appendingPathComponent("llama-server-\(port).auth-token")
        try? FileManager.default.removeItem(at: tokenFile)
        defer { try? FileManager.default.removeItem(at: tokenFile) }
        let server = LlamaServer(port: port, contextTokens: 512, extraArgs: [])

        let first = await server.authenticationToken()
        let second = await server.authenticationToken()

        XCTAssertEqual(first, second, "token must be stable across reads")
        XCTAssertGreaterThanOrEqual(first.count, 32)
        XCTAssertFalse(first.contains("-"))
    }
}
