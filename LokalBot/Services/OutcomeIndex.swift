import Foundation

struct MeetingOutcomeProjection: Identifiable, Equatable, Sendable {
    let meeting: Meeting
    var outcomes: MeetingOutcomes
    var state: MeetingOutcomeState
    var followUp: FollowUpDraft

    var id: Meeting.ID { meeting.id }

    var actionReferences: [OutcomeActionReference] {
        outcomes.actionItems.map { action in
            let userState = state.state(for: action)
            return OutcomeActionReference(
                meetingID: meeting.id,
                meetingTitle: meeting.displayTitle,
                meetingStartedAt: meeting.startedAt,
                action: action,
                status: userState.status,
                text: userState.textCorrection ?? action.text,
                owner: userState.ownerOverride ?? action.owner,
                due: userState.dueOverride ?? action.due)
        }
    }

    /// One loader for UI surfaces and background routines. Keeping the merge
    /// here prevents exports from silently falling back to immutable extraction
    /// after the user has completed or corrected an action in the app.
    static func load(for meeting: Meeting, storage: StorageManager) -> Self? {
        let folder = meeting.folderURL(in: storage)
        guard let outcomes = MeetingOutcomes.load(from: folder) else { return nil }
        let state = MeetingOutcomeStore.loadState(from: folder)
        let followUp = MeetingOutcomeStore.loadFollowUp(from: folder)
            ?? FollowUpDraft.seeded(for: meeting, outcomes: outcomes)
        return Self(meeting: meeting, outcomes: outcomes, state: state, followUp: followUp)
    }
}

struct OutcomeActionReference: Identifiable, Equatable, Sendable {
    let meetingID: Meeting.ID
    let meetingTitle: String
    let meetingStartedAt: Date
    let action: MeetingOutcomes.ActionItem
    var status: OutcomeStatus
    var text: String
    var owner: String?
    var due: String?

    var id: String { "\(meetingID.uuidString):\(action.id)" }
    var isForUser: Bool {
        owner?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Me") == .orderedSame
    }
}

/// Read model shared by Today, Timeline, Meetings, Ask, and Agent. Every
/// mutation is persisted atomically in the relevant meeting folder before the
/// published projection is replaced.
@MainActor
final class OutcomeIndex: ObservableObject {
    @Published private(set) var projections: [Meeting.ID: MeetingOutcomeProjection] = [:]

    private let storage: StorageManager
    private(set) var lastError: String?

    init(storage: StorageManager) {
        self.storage = storage
    }

    var all: [MeetingOutcomeProjection] {
        projections.values.sorted { $0.meeting.startedAt > $1.meeting.startedAt }
    }

    var openUserActions: [OutcomeActionReference] {
        all.flatMap(\.actionReferences)
            .filter { $0.isForUser && $0.status == .open }
            .sorted { $0.meetingStartedAt > $1.meetingStartedAt }
    }

    var recentDecisions: [(meeting: Meeting, decision: MeetingOutcomes.Decision)] {
        all.flatMap { projection in
            projection.outcomes.decisionRecords.map { (projection.meeting, $0) }
        }.sorted { $0.meeting.startedAt > $1.meeting.startedAt }
    }

    func projection(for meetingID: Meeting.ID) -> MeetingOutcomeProjection? {
        projections[meetingID]
    }

    func refresh(meetings: [Meeting]) {
        var next: [Meeting.ID: MeetingOutcomeProjection] = [:]
        for meeting in meetings {
            if let projection = loadProjection(for: meeting) {
                next[meeting.id] = projection
            }
        }
        projections = next
    }

    func refresh(meeting: Meeting) {
        if let projection = loadProjection(for: meeting) {
            projections[meeting.id] = projection
        } else {
            projections.removeValue(forKey: meeting.id)
        }
    }

    @discardableResult
    func setStatus(_ status: OutcomeStatus, actionID: String,
                   meetingID: Meeting.ID) -> Bool {
        mutateAction(actionID: actionID, meetingID: meetingID) { state in
            state.status = status
            state.userEdited = true
        }
    }

    @discardableResult
    func correctAction(actionID: String, meetingID: Meeting.ID,
                       text: String?, owner: String?, due: String?) -> Bool {
        mutateAction(actionID: actionID, meetingID: meetingID) { state in
            state.textCorrection = Self.nilIfBlank(text)
            state.ownerOverride = Self.nilIfBlank(owner)
            state.dueOverride = Self.nilIfBlank(due)
            state.userEdited = true
        }
    }

    @discardableResult
    func saveFollowUp(_ draft: FollowUpDraft, meetingID: Meeting.ID) -> Bool {
        guard var projection = projections[meetingID] else { return false }
        var next = draft
        next.updatedAt = Date().outcomePersistedTimestamp
        next.seeded = false
        next.sourceMeetingID = meetingID
        do {
            try MeetingOutcomeStore.writeFollowUp(
                next, to: projection.meeting.folderURL(in: storage))
            projection.followUp = next
            projections[meetingID] = projection
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func mutateAction(actionID: String, meetingID: Meeting.ID,
                              change: (inout MeetingOutcomeState.ActionState) -> Void) -> Bool {
        guard var projection = projections[meetingID] else { return false }
        var actionState = projection.state.actions[actionID] ?? .init()
        change(&actionState)
        actionState.updatedAt = Date().outcomePersistedTimestamp
        projection.state.actions[actionID] = actionState
        do {
            try MeetingOutcomeStore.writeState(
                projection.state, to: projection.meeting.folderURL(in: storage))
            projections[meetingID] = projection
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func loadProjection(for meeting: Meeting) -> MeetingOutcomeProjection? {
        MeetingOutcomeProjection.load(for: meeting, storage: storage)
    }

    private static func nilIfBlank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
