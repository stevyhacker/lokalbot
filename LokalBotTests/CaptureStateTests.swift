import XCTest
@testable import LokalBot

/// The Capture section's pure policies (spec §2.2 + §6): the Day⇄Library
/// scope default and the selection→inspector-state resolution, testable
/// without any view or AppState.
final class CaptureStateTests: XCTestCase {

    // MARK: Scope policy (open question 2 — resolved yes)

    func testFirstVisitWithBlocksDefaultsToDay() {
        XCTAssertEqual(CaptureScopePolicy.resolve(current: nil, hasBlocks: true), .day)
    }

    func testFirstVisitWithoutBlocksDefaultsToLibrary() {
        XCTAssertEqual(CaptureScopePolicy.resolve(current: nil, hasBlocks: false), .library)
    }

    func testExplicitScopeSticksRegardlessOfBlocks() {
        XCTAssertEqual(CaptureScopePolicy.resolve(current: .library, hasBlocks: true), .library)
        XCTAssertEqual(CaptureScopePolicy.resolve(current: .day, hasBlocks: false), .day)
    }

    // MARK: Inspector state (meeting vs. block vs. none)

    func testSingleMeetingSelectionWinsOverBlock() {
        let id = UUID()
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [id], blockSelection: 7),
            .meeting(id))
    }

    func testMultiSelectionMapsToCount() {
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [UUID(), UUID()], blockSelection: nil),
            .multiSelection(count: 2))
    }

    func testBlockSelectionWithoutMeetingSelection() {
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [], blockSelection: 42),
            .block(42))
    }

    func testNothingSelectedIsOverview() {
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [], blockSelection: nil),
            .overview)
    }
}
