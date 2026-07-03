import CoreGraphics
import XCTest
@testable import LokalBot

/// The inserter posts real CGEvents into whatever has focus, so only its
/// non-posting surface is testable: the synthetic-event marker and the
/// scrub-then-bail guards that must reject no-op inserts before any event
/// exists. Everything past those guards types into the frontmost app and is
/// covered by the Cotyping UI test instead.
final class CotypingInserterTests: XCTestCase {
    // MARK: - Synthetic marker

    func testMarkerTagsAnEventAndRecognizesIt() throws {
        let event = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))

        XCTAssertFalse(CotypingSyntheticMarker.isSynthetic(event),
                       "a fresh event must not read as synthetic")
        CotypingSyntheticMarker.mark(event)
        XCTAssertTrue(CotypingSyntheticMarker.isSynthetic(event))
    }

    func testSuppressionControllerForwardsTheMarker() throws {
        let controller = CotypingInputSuppressionController()
        let event = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))

        XCTAssertFalse(controller.isSynthetic(event))
        controller.markSynthetic(event)
        XCTAssertTrue(controller.isSynthetic(event))
    }

    // MARK: - No-op guards (must return false before any event is created)

    @MainActor
    func testInsertRejectsEmptyAndCarriageReturnOnlyText() {
        let inserter = CotypingInserter()

        XCTAssertFalse(inserter.insert(""))
        XCTAssertFalse(inserter.insert("\r"),
                       "carriage returns are scrubbed; a CR-only insert is a no-op")
        XCTAssertFalse(inserter.insert("\r\r"))
    }

    @MainActor
    func testReplaceRejectsNothingToDeleteAndNothingToType() {
        let inserter = CotypingInserter()

        XCTAssertFalse(inserter.replace(deletingCharacters: 0, with: ""))
        XCTAssertFalse(inserter.replace(deletingCharacters: 0, with: "\r"))
        XCTAssertFalse(inserter.replace(deletingCharacters: -3, with: ""))
    }

    @MainActor
    func testReplaceForwardRejectsNothingToDeleteAndNothingToType() {
        let inserter = CotypingInserter()

        XCTAssertFalse(inserter.replaceForward(deletingCharacters: 0, with: ""))
        XCTAssertFalse(inserter.replaceForward(deletingCharacters: 0, with: "\r"))
    }

    @MainActor
    func testInsertViaPasteRejectsEmptyText() {
        let inserter = CotypingInserter()

        XCTAssertFalse(inserter.insertViaPaste(""),
                       "an empty paste must bail before touching the pasteboard")
        XCTAssertFalse(inserter.insertViaPaste("\r"))
    }
}
