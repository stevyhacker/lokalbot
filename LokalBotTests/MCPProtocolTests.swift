import XCTest
@testable import LokalBot

final class MCPProtocolTests: XCTestCase {
    func testParsesRequestWithNumberID() {
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        guard case .request(let request) = MCPRequest.parse(line) else {
            return XCTFail("expected a request")
        }
        XCTAssertEqual(request.id, .number(1))
        XCTAssertEqual(request.method, "tools/list")
        XCTAssertNil(request.params)
    }

    func testParsesRequestWithStringIDAndParams() {
        let line = #"{"jsonrpc":"2.0","id":"abc","method":"tools/call","params":{"name":"list_meetings"}}"#
        guard case .request(let request) = MCPRequest.parse(line) else {
            return XCTFail("expected a request")
        }
        XCTAssertEqual(request.id, .string("abc"))
        XCTAssertEqual(request.params?["name"]?.stringValue, "list_meetings")
    }

    func testNotificationHasNilID() {
        let line = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        guard case .request(let request) = MCPRequest.parse(line) else {
            return XCTFail("expected a request")
        }
        XCTAssertNil(request.id)
    }

    func testMalformedJSONIsParseError() {
        guard case .failure(let code, _, let id) = MCPRequest.parse("{nope") else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(code, -32700)
        XCTAssertNil(id)
    }

    func testMissingMethodIsInvalidRequestEchoingID() {
        guard case .failure(let code, _, let id) = MCPRequest.parse(#"{"jsonrpc":"2.0","id":7}"#) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(code, -32600)
        XCTAssertEqual(id, .number(7))
    }

    func testWrongJSONRPCVersionIsInvalidRequest() {
        guard case .failure(let code, _, _) = MCPRequest.parse(#"{"jsonrpc":"1.0","id":1,"method":"x"}"#) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(code, -32600)
    }

    func testSuccessResponseIsSingleLineWithSortedKeys() {
        let line = MCPResponse.success(id: .number(3), result: .object(["ok": .bool(true)]))
        XCTAssertEqual(line, #"{"id":3,"jsonrpc":"2.0","result":{"ok":true}}"#)
        XCTAssertFalse(line.contains("\n"))
    }

    func testErrorResponseWithNullID() {
        let line = MCPResponse.failure(id: nil, code: -32700, message: "Parse error")
        XCTAssertEqual(line, #"{"error":{"code":-32700,"message":"Parse error"},"id":null,"jsonrpc":"2.0"}"#)
    }

    func testIntegersSurviveTheJSONValueRoundTrip() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"limit":12}"#.utf8))
        XCTAssertEqual(value["limit"]?.intValue, 12)
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"{"limit":12}"#)
    }
}
