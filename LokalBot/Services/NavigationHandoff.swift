import Combine
import Foundation

struct AskNavigationHandoff: Equatable, Sendable {
    let query: String?
    let dayScope: Date?
    let screenSnapshotIDs: [Int64]
    let submit: Bool
}

struct MeetingSeekHandoff: Equatable, Sendable {
    let meetingID: Meeting.ID
    let seconds: TimeInterval
}

struct AgentLaunchContext: Equatable, Sendable {
    let title: String
    let prompt: String
    let meetingID: Meeting.ID?
    let actionID: String?
}

/// Owns the short-lived payloads passed between navigation destinations.
/// Each destination consumes its complete payload at once, so SwiftUI view
/// mounting and coalesced state updates cannot split or misroute a handoff.
@MainActor
final class NavigationHandoff: ObservableObject {
    @Published private(set) var revision: UInt = 0

    private var pendingAsk: AskNavigationHandoff?
    private var pendingMeetingSeek: MeetingSeekHandoff?
    private var pendingScreenSnapshotID: Int64?
    private(set) var agentContext: AgentLaunchContext?

    func stageAsk(
        query: String,
        dayScope: Date?,
        screenSnapshotIDs: [Int64],
        submit: Bool
    ) {
        pendingAsk = AskNavigationHandoff(
            query: query.isEmpty ? nil : query,
            dayScope: dayScope,
            screenSnapshotIDs: screenSnapshotIDs,
            submit: submit)
        changed()
    }

    func consumeAsk() -> AskNavigationHandoff? {
        guard let pendingAsk else { return nil }
        self.pendingAsk = nil
        changed()
        return pendingAsk
    }

    /// Every meeting navigation replaces the previous seek request. Opening a
    /// meeting without a timestamp therefore cannot inherit an older seek.
    func stageMeeting(_ meetingID: Meeting.ID, seek seconds: TimeInterval?) {
        pendingMeetingSeek = seconds.map {
            MeetingSeekHandoff(meetingID: meetingID, seconds: $0)
        }
        changed()
    }

    func consumeMeetingSeek(for meetingID: Meeting.ID) -> TimeInterval? {
        guard pendingMeetingSeek?.meetingID == meetingID,
              let seconds = pendingMeetingSeek?.seconds else { return nil }
        pendingMeetingSeek = nil
        changed()
        return seconds
    }

    func stageScreenSnapshot(_ snapshotID: Int64) {
        pendingScreenSnapshotID = snapshotID
        changed()
    }

    func consumeScreenSnapshot() -> Int64? {
        guard let pendingScreenSnapshotID else { return nil }
        self.pendingScreenSnapshotID = nil
        changed()
        return pendingScreenSnapshotID
    }

    func stageAgent(_ context: AgentLaunchContext?) {
        agentContext = context
        changed()
    }

    @discardableResult
    func consumeAgentContext() -> AgentLaunchContext? {
        guard let agentContext else { return nil }
        self.agentContext = nil
        changed()
        return agentContext
    }

    private func changed() {
        revision &+= 1
    }
}
