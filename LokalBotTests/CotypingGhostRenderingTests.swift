import AppKit
import XCTest
@testable import LokalBot

// MARK: - Overlay geometry

final class CotypingSuggestionFadeInPolicyTests: XCTestCase {
    func testFadesOnlyOnFreshAppearanceWhenEnabledAndMotionAllowed() {
        XCTAssertTrue(CotypingSuggestionFadeInPolicy.shouldFadeIn(
            isEnabled: true,
            overlayWasVisible: false,
            reduceMotionEnabled: false))
        XCTAssertFalse(CotypingSuggestionFadeInPolicy.shouldFadeIn(
            isEnabled: true,
            overlayWasVisible: true,
            reduceMotionEnabled: false))
    }

    func testDisabledAndReduceMotionBothSuppressFade() {
        XCTAssertFalse(CotypingSuggestionFadeInPolicy.shouldFadeIn(
            isEnabled: false,
            overlayWasVisible: false,
            reduceMotionEnabled: false))
        XCTAssertFalse(CotypingSuggestionFadeInPolicy.shouldFadeIn(
            isEnabled: true,
            overlayWasVisible: false,
            reduceMotionEnabled: true))
    }

    func testFadeDurationClampUsesCotypistBand() {
        XCTAssertEqual(
            CotypingSuggestionFadeInPolicy.clampedDurationSeconds(0.001),
            CotypingSuggestionFadeInPolicy.minimumDurationSeconds,
            accuracy: 0.0001)
        XCTAssertEqual(
            CotypingSuggestionFadeInPolicy.clampedDurationSeconds(2),
            CotypingSuggestionFadeInPolicy.maximumDurationSeconds,
            accuracy: 0.0001)
        XCTAssertEqual(
            CotypingSuggestionFadeInPolicy.clampedDurationSeconds(.infinity),
            CotypingSuggestionFadeInPolicy.defaultDurationSeconds,
            accuracy: 0.0001)
    }
}

final class CotypingGhostHighlightTests: XCTestCase {
    func testHighlightsNextAcceptedLatinChunk() {
        XCTAssertEqual(CotypingGhostHighlight.acceptancePrefix(in: "hello world"), "hello")
        XCTAssertEqual(CotypingGhostHighlight.acceptancePrefix(in: "done\nnext"), "done")
    }

    func testHighlightsNextAcceptedSpacelessScriptChunk() {
        let run = "\u{4f60}\u{597d}\u{4e16}\u{754c}"
        let prefix = CotypingGhostHighlight.acceptancePrefix(in: run)
        XCTAssertFalse(prefix.isEmpty)
        XCTAssertTrue(run.hasPrefix(prefix))
        XCTAssertLessThan(prefix.count, run.count)
    }

    func testHighlightsBoundCJKPunctuationChunk() {
        XCTAssertEqual(
            CotypingGhostHighlight.acceptancePrefix(in: "\u{8cc7}\u{6599}\u{3001}\u{5185}\u{5bb9}"),
            "\u{8cc7}\u{6599}\u{3001}")
    }
}

final class CotypingTextDirectionDetectorTests: XCTestCase {
    func testDetectsRTLNearCaret() {
        XCTAssertTrue(CotypingTextDirectionDetector.isRightToLeft("hello \u{05E9}\u{05DC}\u{05D5}\u{05DD}"))
    }

    func testRecentStrongLTRWinsOverEarlierRTL() {
        XCTAssertFalse(CotypingTextDirectionDetector.isRightToLeft("\u{05E9}\u{05DC}\u{05D5}\u{05DD} hello"))
    }

    func testFallsBackToLTRWhenNoStrongDirection() {
        XCTAssertFalse(CotypingTextDirectionDetector.isRightToLeft("1234 ..."))
    }
}
