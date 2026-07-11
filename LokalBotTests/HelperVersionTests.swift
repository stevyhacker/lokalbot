import XCTest
@testable import LokalBot

final class HelperVersionTests: XCTestCase {
    func testReadsVersionFromEnclosingAppBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helperversion-\(UUID().uuidString)")
        let helpers = root.appendingPathComponent("Fake.app/Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "9.9.9"],
            format: .xml,
            options: 0)
        try plist.write(to: root.appendingPathComponent("Fake.app/Contents/Info.plist"))
        let binary = helpers.appendingPathComponent("lokalbot-cli")
        try Data().write(to: binary)

        XCTAssertEqual(HelperVersion.current(binaryPath: binary.path), "9.9.9")
    }

    func testFallsBackToDevOutsideABundle() {
        XCTAssertEqual(HelperVersion.current(binaryPath: "/tmp/loose-binary"), "dev")
    }
}
