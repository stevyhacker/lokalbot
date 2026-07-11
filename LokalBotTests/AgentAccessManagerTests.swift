import XCTest
@testable import LokalBot

@MainActor
final class AgentAccessManagerTests: XCTestCase {
    private var root: URL!
    private var gate: AgentAccessGate!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("accessmanager-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        gate = AgentAccessGate(root: root)
    }

    override func tearDown() {
        unsetenv("LOKALBOT_STORAGE_ROOT")
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeManager(
        startEngine: @escaping (AppSettings, StorageManager) async -> String? = { _, _ in nil }
    ) -> AgentAccessManager {
        AgentAccessManager(
            storage: StorageManager(),
            settings: { AppSettings() },
            gate: gate,
            startEngine: startEngine)
    }

    func testToggleMirrorsMarkerFile() {
        let manager = makeManager()
        manager.start()
        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(gate.isEnabled)

        manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertTrue(gate.isEnabled)

        manager.setEnabled(false)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(gate.isEnabled)
    }

    func testStartResumesEnabledStateFromMarker() throws {
        try gate.enable()
        let manager = makeManager()
        manager.start()
        XCTAssertTrue(manager.isEnabled)
    }

    func testWakeTouchStartsEngineAndConsumesWake() async throws {
        let woke = expectation(description: "engine started")
        let manager = makeManager { _, _ in
            woke.fulfill()
            return nil
        }
        manager.setEnabled(true)

        try gate.touchWake()
        await fulfillment(of: [woke], timeout: 5)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(gate.pendingWake)
        XCTAssertNil(gate.readWakeError())
    }

    func testEngineFailureWritesWakeErrorFile() async throws {
        let failed = expectation(description: "engine refused")
        let manager = makeManager { _, _ in
            failed.fulfill()
            return "The built-in model isn't downloaded."
        }
        manager.setEnabled(true)

        try gate.touchWake()
        await fulfillment(of: [failed], timeout: 5)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(
            gate.readWakeError(),
            "The built-in model isn't downloaded.")
    }

    func testNoWakeHandlingAfterDisable() async throws {
        let woke = expectation(description: "engine started")
        woke.isInverted = true
        let manager = makeManager { _, _ in
            woke.fulfill()
            return nil
        }
        manager.setEnabled(true)
        manager.setEnabled(false)

        try? gate.touchWake()
        await fulfillment(of: [woke], timeout: 1)
    }
}
