import XCTest
@testable import LokalBot

final class InferenceEndpointPolicyTests: XCTestCase {
    func testLoopbackEndpointsDoNotRequireApproval() throws {
        for value in ["http://localhost:11434", "http://127.0.0.1:8080", "http://[::1]:9000"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertTrue(InferenceEndpointPolicy.isAllowed(url, approvedOrigins: []), value)
            XCTAssertNoThrow(try InferenceEndpointPolicy.validate(url, approvedOrigins: []), value)
        }
    }

    func testRemoteEndpointRequiresItsExactOrigin() throws {
        let url = try XCTUnwrap(URL(string: "https://inference.example.com/v1/chat/completions"))

        XCTAssertThrowsError(try InferenceEndpointPolicy.validate(url, approvedOrigins: []))
        XCTAssertNoThrow(try InferenceEndpointPolicy.validate(
            url, approvedOrigins: ["https://inference.example.com"]))
        XCTAssertThrowsError(try InferenceEndpointPolicy.validate(
            url, approvedOrigins: ["https://other.example.com"]))
    }

    func testOnlyHTTPInferenceURLsAreAccepted() throws {
        let fileURL = try XCTUnwrap(URL(string: "file:///tmp/model"))
        XCTAssertThrowsError(try InferenceEndpointPolicy.validate(fileURL, approvedOrigins: []))
    }
}
