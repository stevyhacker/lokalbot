import XCTest
@testable import LokalBot

final class ScreenMemoryAccessGateTests: XCTestCase {
    private func makeGates() -> (ScreenMemoryAccessGate, AgentAccessGate, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-memory-gate-\(UUID().uuidString)", isDirectory: true)
        return (
            ScreenMemoryAccessGate(root: root),
            AgentAccessGate(root: root),
            root)
    }

    func testDisabledByDefaultAndUsesDistinctMarker() throws {
        let (screenGate, meetingGate, root) = makeGates()
        defer { try? FileManager.default.removeItem(at: root) }

        try meetingGate.enable()
        XCTAssertTrue(meetingGate.isAuthorized(environment: [:]))
        XCTAssertFalse(screenGate.isAuthorized(),
                       "the meeting marker must not authorize screen memory")

        try screenGate.enable()
        XCTAssertTrue(screenGate.isAuthorized())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root
            .appendingPathComponent("control/screen-memory-access-enabled").path))

        meetingGate.disable()
        XCTAssertTrue(screenGate.isAuthorized(),
                      "disabling meeting access must not remove the screen marker")
        screenGate.disable()
        XCTAssertFalse(screenGate.isAuthorized())
    }

    func testEnableHardensExistingControlDirectoryAndMarkerPermissions() throws {
        let (screenGate, _, root) = makeGates()
        defer { try? FileManager.default.removeItem(at: root) }
        let control = root.appendingPathComponent("control", isDirectory: true)
        try FileManager.default.createDirectory(
            at: control,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: control.path)

        try screenGate.enable()

        let directoryMode = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: control.path)[.posixPermissions] as? NSNumber).intValue & 0o777
        let markerMode = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: screenGate.accessMarkerURL.path)[.posixPermissions] as? NSNumber)
            .intValue & 0o777
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(markerMode, 0o600)
    }

    func testDefaultRootFollowsStorageRootOverride() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-memory-env-\(UUID().uuidString)", isDirectory: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            unsetenv("LOKALBOT_STORAGE_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertEqual(ScreenMemoryAccessGate().root.path, root.path)
    }
}

@MainActor
final class ScreenMemoryAccessManagerTests: XCTestCase {
    func testManagerMirrorsOnlyScreenMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-memory-manager-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let screenGate = ScreenMemoryAccessGate(root: root)
        let meetingGate = AgentAccessGate(root: root)
        let manager = ScreenMemoryAccessManager(gate: screenGate)

        try meetingGate.enable()
        manager.start()
        XCTAssertFalse(manager.isEnabled)

        manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertTrue(screenGate.isEnabled)

        manager.setEnabled(false)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(screenGate.isEnabled)
        XCTAssertTrue(meetingGate.isEnabled)
    }
}
