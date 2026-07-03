import XCTest
@testable import LokalBot

/// The Timeline/Meetings detail pane's pure policy (spec §2.2 + §6): the
/// selection→inspector-state resolution, testable without any view or
/// AppState.
final class CaptureStateTests: XCTestCase {

    // MARK: Inspector state (meeting vs. block vs. none)

    func testSingleMeetingSelectionWinsOverBlock() {
        let id = UUID()
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [id], blockSelection: 7,
                                          allowsBlockSelection: true),
            .meeting(id))
    }

    func testMultiSelectionMapsToCount() {
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [UUID(), UUID()], blockSelection: nil,
                                          allowsBlockSelection: true),
            .multiSelection(count: 2))
    }

    func testBlockSelectionWithoutMeetingSelection() {
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [], blockSelection: 42,
                                          allowsBlockSelection: true),
            .block(42))
    }

    /// A block picked in Timeline lingers in the shared model; on a surface
    /// without a block list (Meetings) it must not outrank the empty state.
    func testStaleBlockSelectionIgnoredWhereBlocksAreNotShown() {
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [], blockSelection: 42,
                                          allowsBlockSelection: false),
            .overview)
    }

    func testNothingSelectedIsOverview() {
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [], blockSelection: nil,
                                          allowsBlockSelection: true),
            .overview)
    }
}
