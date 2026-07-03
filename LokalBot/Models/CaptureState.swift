import Foundation

/// Which surface the Capture content column shows (spec §2.2): the
/// hour-track Day view or the grouped-by-day meeting Library.
enum CaptureScope: String, CaseIterable, Identifiable {
    case day = "Day"
    case library = "Library"
    var id: String { rawValue }
}

/// Pure scope-default policy: the first visit lands on Day when the selected
/// day has activity blocks and on Library otherwise (spec open question 2 —
/// resolved yes); once a scope is set (user toggle or deep link) it sticks.
enum CaptureScopePolicy {
    static func resolve(current: CaptureScope?, hasBlocks: Bool) -> CaptureScope {
        current ?? (hasBlocks ? .day : .library)
    }
}

/// What the Capture detail pane shows, resolved from the two selection
/// sources (spec §2.2): meeting selection wins, then an activity block,
/// then the day overview. Multi-selected meetings keep the bulk-delete card.
enum CaptureInspectorState: Equatable {
    case overview
    case meeting(Meeting.ID)
    case multiSelection(count: Int)
    case block(ActivityBlock.ID)

    static func resolve(meetingIDs: Set<Meeting.ID>,
                        blockSelection: ActivityBlock.ID?) -> CaptureInspectorState {
        if meetingIDs.count == 1, let id = meetingIDs.first { return .meeting(id) }
        if meetingIDs.count > 1 { return .multiSelection(count: meetingIDs.count) }
        if let blockSelection { return .block(blockSelection) }
        return .overview
    }
}
