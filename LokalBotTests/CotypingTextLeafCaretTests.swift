import XCTest
@testable import LokalBot

/// The leaf-derived caret fallback for Chromium/Electron editables. The main
/// scenario's numbers are real: measured via an AX probe against Discord's
/// message composer (Slate contenteditable) with the draft "test this u".
final class CotypingTextLeafCaretTests: XCTestCase {
    private let composerFrame = CGRect(x: 455, y: 1052, width: 795, height: 56)
    private let composerLeaf = CotypingTextLeafCaret.Leaf(
        frame: CGRect(x: 455, y: 1069, width: 69, height: 22), text: "test this u")

    private func derive(
        leaves: [CotypingTextLeafCaret.Leaf],
        fieldText: String,
        caretLocation: Int,
        isRightToLeft: Bool = false
    ) -> CGRect? {
        CotypingTextLeafCaret.caretRect(
            elementFrame: composerFrame,
            leaves: leaves,
            fieldText: fieldText,
            caretLocation: caretLocation,
            isRightToLeft: isRightToLeft)
    }

    func testDiscordComposerCaretIsLeafTrailingEdge() {
        let rect = derive(leaves: [composerLeaf], fieldText: "test this u", caretLocation: 11)
        XCTAssertEqual(rect, CGRect(x: 524, y: 1069, width: 1, height: 22))
    }

    func testTrailingNewlineFromContenteditableIsTolerated() {
        // Draft/Slate keep a trailing "\n" in the reported value while the
        // caret index stays at the visible end of the text.
        let rect = derive(leaves: [composerLeaf], fieldText: "test this u\n", caretLocation: 11)
        XCTAssertEqual(rect?.origin.x, 524)
    }

    func testMidTextCaretRefusesDerivation() {
        XCTAssertNil(derive(leaves: [composerLeaf], fieldText: "test this u", caretLocation: 5))
    }

    func testCaretIsAtTextEndPreCheck() {
        XCTAssertTrue(CotypingTextLeafCaret.caretIsAtTextEnd(fieldText: "\n", caretLocation: 0))
        XCTAssertTrue(CotypingTextLeafCaret.caretIsAtTextEnd(fieldText: "ab\n", caretLocation: 2))
        XCTAssertFalse(CotypingTextLeafCaret.caretIsAtTextEnd(fieldText: "ab\ncd", caretLocation: 2))
    }

    func testLastLeafOfStyledLineWins() {
        // A bold tail splits the line into two runs; the caret follows the last.
        let head = CotypingTextLeafCaret.Leaf(
            frame: CGRect(x: 455, y: 1069, width: 30, height: 22), text: "test ")
        let tail = CotypingTextLeafCaret.Leaf(
            frame: CGRect(x: 485, y: 1069, width: 39, height: 22), text: "this u")
        let rect = derive(leaves: [head, tail], fieldText: "test this u", caretLocation: 11)
        XCTAssertEqual(rect?.origin.x, 524)
    }

    func testNewlineOnlyLeavesAreSkipped() {
        let ghostRun = CotypingTextLeafCaret.Leaf(
            frame: CGRect(x: 455, y: 1091, width: 1, height: 22), text: "\n")
        let rect = derive(leaves: [composerLeaf, ghostRun], fieldText: "test this u", caretLocation: 11)
        XCTAssertEqual(rect?.origin.x, 524)
    }

    func testFieldTextNotEndingWithLastRunRefuses() {
        // A trailing emoji/mention the runs don't cover would put the caret
        // past the last text run — refuse rather than misplace the ghost.
        XCTAssertNil(derive(leaves: [composerLeaf], fieldText: "test this u😀", caretLocation: 13))
    }

    func testLeafOutsideElementFrameRefuses() {
        let strayLeaf = CotypingTextLeafCaret.Leaf(
            frame: CGRect(x: 1728, y: 82, width: 40, height: 19), text: "test this u")
        XCTAssertNil(derive(leaves: [strayLeaf], fieldText: "test this u", caretLocation: 11))
    }

    func testUnreasonableLineHeightRefuses() {
        let blockSizedLeaf = CotypingTextLeafCaret.Leaf(
            frame: CGRect(x: 455, y: 1052, width: 69, height: 200), text: "test this u")
        XCTAssertNil(derive(leaves: [blockSizedLeaf], fieldText: "test this u", caretLocation: 11))
    }

    func testNoLeavesRefuses() {
        XCTAssertNil(derive(leaves: [], fieldText: "\n", caretLocation: 0))
    }

    func testRightToLeftUsesLeadingEdge() {
        let rtlLeaf = CotypingTextLeafCaret.Leaf(
            frame: CGRect(x: 1100, y: 1069, width: 69, height: 22), text: "שלום")
        let rect = derive(leaves: [rtlLeaf], fieldText: "שלום", caretLocation: 4, isRightToLeft: true)
        XCTAssertEqual(rect?.origin.x, 1100)
    }
}
