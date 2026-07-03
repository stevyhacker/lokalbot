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
