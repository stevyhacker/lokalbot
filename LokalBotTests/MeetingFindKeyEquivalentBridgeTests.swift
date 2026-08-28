import AppKit
import XCTest
@testable import LokalBot

@MainActor
final class MeetingFindKeyEquivalentBridgeTests: XCTestCase {
    func testPlainCommandFInvokesMeetingFind() {
        let view = MeetingFindKeyEquivalentView()
        var invocationCount = 0
        view.onFind = { invocationCount += 1 }

        XCTAssertTrue(view.performKeyEquivalent(with: keyEvent(modifiers: .command)))
        XCTAssertEqual(invocationCount, 1)
    }

    func testModifiedCommandFRemainsOnResponderChain() {
        let view = MeetingFindKeyEquivalentView()
        var invocationCount = 0
        view.onFind = { invocationCount += 1 }

        XCTAssertFalse(view.performKeyEquivalent(
            with: keyEvent(modifiers: [.command, .shift])))
        XCTAssertEqual(invocationCount, 0)
    }

    private func keyEvent(modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "f",
            charactersIgnoringModifiers: "f",
            isARepeat: false,
            keyCode: 3)!
    }
}
