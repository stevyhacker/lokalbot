import AppKit
import XCTest
@testable import LokalBot

// MARK: - Insertion strategy (keystroke vs paste)

final class CotypingInsertionStrategyTests: XCTestCase {
    func testDisabledAlwaysKeystroke() {
        XCTAssertEqual(CotypingInsertionStrategySelector.select(forChunk: "line one\nline two", pasteEnabled: false), .keystroke)
        XCTAssertEqual(CotypingInsertionStrategySelector.select(forChunk: String(repeating: "x", count: 200), pasteEnabled: false), .keystroke)
    }

    func testMultilinePastes() {
        XCTAssertEqual(CotypingInsertionStrategySelector.select(forChunk: "a\nb", pasteEnabled: true), .paste)
    }

    func testLongPastes() {
        XCTAssertEqual(CotypingInsertionStrategySelector.select(forChunk: String(repeating: "x", count: 80), pasteEnabled: true), .paste)
        XCTAssertEqual(CotypingInsertionStrategySelector.select(forChunk: String(repeating: "x", count: 200), pasteEnabled: true), .paste)
    }

    func testShortSingleLineKeystrokes() {
        XCTAssertEqual(CotypingInsertionStrategySelector.select(forChunk: "hello world", pasteEnabled: true), .keystroke)
        XCTAssertEqual(CotypingInsertionStrategySelector.select(forChunk: String(repeating: "x", count: 79), pasteEnabled: true), .keystroke)
    }

    func testComposingIMEAlwaysPastes() {
        XCTAssertEqual(
            CotypingInsertionStrategySelector.select(
                forChunk: "short",
                pasteEnabled: false,
                isComposingIMEActive: true),
            .paste)
    }

    func testPasteInsertionDefaultsOn() {
        XCTAssertTrue(AppSettings().cotypingPasteInsertion)
    }
}

// MARK: - IME composition input modes

final class CotypingCompositionInputModeClassifierTests: XCTestCase {
    func testPlainKeyboardLayoutIsNotComposing() {
        XCTAssertFalse(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: true,
                inputModeID: nil))
    }

    func testKnownComposingModesAreComposing() {
        XCTAssertTrue(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.Japanese.Hiragana"))
        XCTAssertTrue(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.SCIM.ITABC"))
        XCTAssertTrue(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.Korean.2SetKorean"))
    }

    func testRomanDirectModeIsNotComposing() {
        XCTAssertFalse(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.Roman"))
    }

    func testUnknownNonLayoutInputMethodIsComposing() {
        XCTAssertTrue(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: nil))
        XCTAssertTrue(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.justsystems.inputmethod.atok33.Japanese"))
    }
}
