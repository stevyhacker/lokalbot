import XCTest
@testable import LokalBot

final class AgentAccessGateTests: XCTestCase {
    private func makeGate() -> (AgentAccessGate, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-gate-\(UUID().uuidString)", isDirectory: true)
        return (AgentAccessGate(root: root), root)
    }

    func testDisabledByDefaultAndEnableDisableRoundTrip() throws {
        let (gate, root) = makeGate()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(gate.isEnabled)
        try gate.enable()
        XCTAssertTrue(gate.isEnabled)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("control/agent-access-enabled").path))
        gate.disable()
        XCTAssertFalse(gate.isEnabled)
    }

    func testWakeTouchConsumeCycle() throws {
        let (gate, root) = makeGate()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(gate.pendingWake)
        XCTAssertFalse(gate.consumeWake())
        try gate.touchWake()
        XCTAssertTrue(gate.pendingWake)
        XCTAssertTrue(gate.consumeWake())
        XCTAssertFalse(gate.pendingWake)
    }

    func testWakeErrorRoundTrip() throws {
        let (gate, root) = makeGate()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(gate.readWakeError())
        gate.writeWakeError("engine offline")
        XCTAssertEqual(gate.readWakeError(), "engine offline")
        gate.clearWakeError()
        XCTAssertNil(gate.readWakeError())
    }

    func testDefaultRootFollowsStorageRootOverride() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-gate-env-\(UUID().uuidString)", isDirectory: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            unsetenv("LOKALBOT_STORAGE_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertEqual(AgentAccessGate().root.path, root.path)
    }
}
