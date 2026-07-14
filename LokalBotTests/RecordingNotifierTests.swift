import XCTest
@testable import LokalBot

@MainActor
final class RecordingPromptRegistryTests: XCTestCase {
    func testInvalidationRemovesStaleRecordActionBeforeReplacement() {
        var registry = RecordingPromptRegistry()
        var recorded: [String] = []
        let now = Date()

        registry.insert(identifier: "old", expiresAt: now.addingTimeInterval(120)) {
            recorded.append("old")
        }
        XCTAssertEqual(Set(registry.removeAll()), ["old"])

        registry.insert(identifier: "current", expiresAt: now.addingTimeInterval(120)) {
            recorded.append("current")
        }
        XCTAssertNil(registry.remove("old"))
        registry.remove("current")?.record()

        XCTAssertEqual(recorded, ["current"])
    }

    func testExpiredPromptIsRemovedWithoutInvalidatingCurrentPrompt() {
        var registry = RecordingPromptRegistry()
        var didRecordCurrent = false
        let now = Date()

        registry.insert(identifier: "expired", expiresAt: now.addingTimeInterval(-1)) {}
        registry.insert(identifier: "current", expiresAt: now.addingTimeInterval(60)) {
            didRecordCurrent = true
        }

        XCTAssertEqual(Set(registry.removeExpired(now: now)), ["expired"])
        XCTAssertNil(registry.remove("expired"))
        registry.remove("current")?.record()
        XCTAssertTrue(didRecordCurrent)
    }
}
