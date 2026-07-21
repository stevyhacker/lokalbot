import AppKit
import XCTest
@testable import LokalBot

// MARK: - Streamed ghost text policy

final class CotypingStreamedGhostTextPolicyTests: XCTestCase {
    func testFirstNonEmptyPartialCanRender() {
        XCTAssertTrue(CotypingStreamedGhostTextPolicy.isRenderableExtension(
            candidate: " up",
            currentlyRendered: nil))
    }

    func testEmptyPartialCannotRender() {
        XCTAssertFalse(CotypingStreamedGhostTextPolicy.isRenderableExtension(
            candidate: "",
            currentlyRendered: nil))
    }

    func testStrictPrefixExtensionCanRender() {
        XCTAssertTrue(CotypingStreamedGhostTextPolicy.isRenderableExtension(
            candidate: " up today",
            currentlyRendered: " up"))
    }

    func testSameOrShorterPartialCannotReplaceRenderedText() {
        XCTAssertFalse(CotypingStreamedGhostTextPolicy.isRenderableExtension(
            candidate: " up",
            currentlyRendered: " up"))
        XCTAssertFalse(CotypingStreamedGhostTextPolicy.isRenderableExtension(
            candidate: " up",
            currentlyRendered: " up today"))
    }

    func testLongerNonPrefixPartialCannotReplaceRenderedText() {
        XCTAssertFalse(CotypingStreamedGhostTextPolicy.isRenderableExtension(
            candidate: " tomorrow",
            currentlyRendered: " today"))
    }

    func testFirstAcceptanceConsumesInFlightStreamFenceExactlyOnce() {
        var fence = CotypingStreamAcceptanceFence()
        fence.markPresented(work: 42)

        XCTAssertEqual(fence.consumeForAcceptance(), 42)
        XCTAssertNil(fence.consumeForAcceptance())
    }

    func testFinalOrClearedPresentationResetsStreamFence() {
        var fence = CotypingStreamAcceptanceFence()
        fence.markPresented(work: 42)
        fence.reset()

        XCTAssertNil(fence.consumeForAcceptance())
    }
}

// MARK: - Streaming SSE parsing

final class CotypingStreamingTests: XCTestCase {
    func testParsesTextDelta() {
        XCTAssertEqual(cotypingParseSSEDelta(#"data: {"choices":[{"text":"eive"}]}"#), "eive")
    }

    func testIgnoresDoneSentinel() {
        XCTAssertNil(cotypingParseSSEDelta("data: [DONE]"))
    }

    func testIgnoresNonDataLines() {
        XCTAssertNil(cotypingParseSSEDelta(""))
        XCTAssertNil(cotypingParseSSEDelta(": keep-alive"))
        XCTAssertNil(cotypingParseSSEDelta("event: message"))
    }

    func testEmptyTextDeltaIsEmptyNotNil() {
        XCTAssertEqual(cotypingParseSSEDelta(#"data: {"choices":[{"text":""}]}"#), "")
    }
}
