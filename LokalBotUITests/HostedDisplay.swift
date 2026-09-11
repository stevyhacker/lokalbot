import CoreGraphics
import Foundation
import XCTest

/// Interactive layout checks need their windows on the real hosted desktop.
/// Native self-captures can rasterize off-screen; mouse-driven tests cannot.
enum HostedDisplay {
    static func prepareForModelLayouts() throws {
        let minimum = CGSize(width: 1600, height: 1000)
        func hasRoom() -> Bool {
            let bounds = CGDisplayBounds(CGMainDisplayID())
            return bounds.width >= minimum.width && bounds.height >= minimum.height
        }
        guard !hasRoom() else { return }
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
            throw NSError(domain: "HostedDisplay", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Model layout tests require a desktop of at least 1600×1000."])
        }
        // GitHub's Anka runners provide this guest display utility:
        // https://github.com/actions/runner-images/issues/9345
        let locations = [
            "/Library/Application Support/Veertu/Anka/addons/change_res",
            "/Library/Application Support/Veertu/Anka/guestaddons/change_res",
        ]
        guard let utility = locations.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "HostedDisplay", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The hosted runner has no Anka display-resizing utility."])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: utility)
        process.arguments = ["1600x1000x32@30"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Could not resize the hosted display")
        XCTAssertTrue(UITestHarness.waitUntil(timeout: 8, hasRoom),
                      "Hosted display must fit the 1440×900 interactive layout")
    }
}
