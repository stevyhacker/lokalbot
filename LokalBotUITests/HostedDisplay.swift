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
        // CI configures the desktop before XCTest starts. XCTest does not
        // inherit ordinary shell environment variables such as GITHUB_ACTIONS.
        XCTAssertTrue(UITestHarness.waitUntil(timeout: 8, hasRoom),
                      "Run Scripts/ci/prepare-display.swift before interactive layout tests")
    }
}
