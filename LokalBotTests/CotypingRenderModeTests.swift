import AppKit
import XCTest
@testable import LokalBot

// MARK: - Mirror render mode

final class CotypingRenderModeTests: XCTestCase {
    func testIsCaretAtEndOfLine() {
        XCTAssertTrue(CotypingRenderModePolicy.isCaretAtEndOfLine(trailingText: ""))
        XCTAssertTrue(CotypingRenderModePolicy.isCaretAtEndOfLine(trailingText: "\nrest"))
        XCTAssertFalse(CotypingRenderModePolicy.isCaretAtEndOfLine(trailingText: "world"))
        XCTAssertFalse(CotypingRenderModePolicy.isCaretAtEndOfLine(trailingText: " \n"))  // leading space = mid-line
    }

    func testAutoExactEndOfLineIsInline() {
        let mode = CotypingRenderModePolicy(userPreference: .auto).mode(caretIsExact: true, isCaretAtEndOfLine: true)
        XCTAssertEqual(mode, .inline)
    }

    func testAutoExactMidLinePromotesToMirror() {
        let mode = CotypingRenderModePolicy(userPreference: .auto).mode(caretIsExact: true, isCaretAtEndOfLine: false)
        XCTAssertEqual(mode, .mirror(reason: .caretMidLine))
    }

    func testAutoEstimatedEndOfLineUsesMirror() {
        let endOfLine = CotypingRenderModePolicy(userPreference: .auto).mode(caretIsExact: false, isCaretAtEndOfLine: true)
        let midLine = CotypingRenderModePolicy(userPreference: .auto).mode(caretIsExact: false, isCaretAtEndOfLine: false)
        XCTAssertEqual(endOfLine, .mirror(reason: .caretGeometryEstimated))
        XCTAssertEqual(midLine, .mirror(reason: .caretMidLine))
    }

    func testAlwaysInlineMidLineStillOverrides() {
        // An explicit inline pin cannot render mid-line, so it is promoted too.
        let mode = CotypingRenderModePolicy(userPreference: .alwaysInline).mode(caretIsExact: true, isCaretAtEndOfLine: false)
        XCTAssertEqual(mode, .mirror(reason: .caretMidLine))
    }

    func testAlwaysInlineEndOfLineIsInline() {
        let mode = CotypingRenderModePolicy(userPreference: .alwaysInline).mode(caretIsExact: true, isCaretAtEndOfLine: true)
        XCTAssertEqual(mode, .inline)
    }

    func testAlwaysMirrorReasonIsUserPreference() {
        let mode = CotypingRenderModePolicy(userPreference: .alwaysMirror).mode(caretIsExact: true, isCaretAtEndOfLine: true)
        XCTAssertEqual(mode, .mirror(reason: .userPreference))
    }

    func testPlacementComposesIntoMode() {
        let inline = CotypingOverlayPlacement(caretIsExact: true, isCaretAtEndOfLine: true, preference: .auto)
        let estimatedEnd = CotypingOverlayPlacement(caretIsExact: false, isCaretAtEndOfLine: true, preference: .auto)
        XCTAssertEqual(inline.mode, .inline)
        XCTAssertEqual(estimatedEnd.mode, .mirror(reason: .caretGeometryEstimated))
    }

    func testPreferenceDefaultsToAuto() {
        XCTAssertEqual(AppSettings().cotypingMirrorPreference, .auto)
    }
}
