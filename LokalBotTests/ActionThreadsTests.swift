import XCTest
@testable import LokalBot

@MainActor
final class ActionThreadsTests: XCTestCase {
    func testClustersCompatibleMentionsAndPrefersUserCorrection() throws {
        let older = reference(
            meetingID: UUID(),
            meetingTitle: "Planning",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            text: "I will send the revised launch proposal",
            due: "Friday")
        let newer = reference(
            meetingID: UUID(),
            meetingTitle: "Client review",
            startedAt: older.meetingStartedAt.addingTimeInterval(2 * 86_400),
            text: "Send the revised launch proposal",
            due: "Monday",
            correctedText: "Send Acme the revised launch proposal",
            correctedDue: "Tuesday")

        let threads = ActionThreadClusterer.cluster([older, newer])

        XCTAssertEqual(threads.count, 1)
        let thread = try XCTUnwrap(threads.first)
        XCTAssertEqual(thread.meetingCount, 2)
        XCTAssertEqual(thread.mentionCount, 2)
        XCTAssertEqual(thread.text, "Send Acme the revised launch proposal")
        XCTAssertEqual(thread.due, "Tuesday")
        XCTAssertEqual(thread.dueHistory, ["Tuesday", "Friday"])
        XCTAssertEqual(thread.references.map(\.meetingTitle), ["Client review", "Planning"])
    }

    func testKeepsGenericConflictingAndDifferentOwnerActionsSeparate() {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let references = [
            reference(
                meetingID: UUID(), meetingTitle: "One", startedAt: start,
                text: "Follow up", owner: "Me"),
            reference(
                meetingID: UUID(), meetingTitle: "Two",
                startedAt: start.addingTimeInterval(60),
                text: "Follow up", owner: "Me"),
            reference(
                meetingID: UUID(), meetingTitle: "Release 72", startedAt: start,
                text: "Ship release 72 candidate today", owner: "Me"),
            reference(
                meetingID: UUID(), meetingTitle: "Release 73",
                startedAt: start.addingTimeInterval(60),
                text: "Ship release 73 candidate today", owner: "Me"),
            reference(
                meetingID: UUID(), meetingTitle: "Ana",
                startedAt: start.addingTimeInterval(120),
                text: "Send the revised launch proposal", owner: "Ana"),
            reference(
                meetingID: UUID(), meetingTitle: "Me",
                startedAt: start.addingTimeInterval(180),
                text: "Send the revised launch proposal", owner: "Me"),
        ]

        XCTAssertEqual(ActionThreadClusterer.cluster(references).count, references.count)
    }

    func testMostRecentSavedStateControlsThreadStatus() throws {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let first = reference(
            meetingID: UUID(),
            meetingTitle: "Planning",
            startedAt: start,
            text: "Send the revised launch proposal",
            status: .open,
            stateUpdatedAt: start.addingTimeInterval(100))
        let completed = reference(
            meetingID: UUID(),
            meetingTitle: "Review",
            startedAt: start.addingTimeInterval(60),
            text: "Send the revised launch proposal",
            status: .done,
            stateUpdatedAt: start.addingTimeInterval(200))

        let thread = try XCTUnwrap(ActionThreadClusterer.cluster([first, completed]).first)

        XCTAssertEqual(thread.status, .done)
    }

    func testSourceCompletionPersistsWholeThreadAndNotifiesOncePerMeeting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("action-thread-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID = UUID()
        let secondID = UUID()
        let startedAt = Date()
        try MeetingFixture.write([
            .init(id: firstID, title: "Planning", startedAt: startedAt),
            .init(
                id: secondID,
                title: "Review",
                startedAt: startedAt.addingTimeInterval(60)),
        ], under: root)
        let storage = StorageManager(rootURL: root)
        let meetings = try SessionLookup.loadAllMeetings(root: root)
        for meeting in meetings {
            try MeetingOutcomes(actionItems: [
                .init(text: "Send the revised launch proposal", owner: "Me"),
            ]).write(to: meeting.folderURL(in: storage))
        }
        var notifications: [Meeting.ID] = []
        let index = OutcomeIndex(storage: storage) { notifications.append($0.id) }
        index.refresh(meetings: meetings)
        let thread = try XCTUnwrap(index.openUserActionThreads.first)
        XCTAssertEqual(thread.meetingCount, 2)

        let source = thread.references[0]
        XCTAssertTrue(index.setStatus(
            .done,
            actionID: source.action.id,
            meetingID: source.meetingID))
        XCTAssertTrue(index.openUserActions.isEmpty)
        XCTAssertEqual(index.userActionThreads.map(\.status), [.done])
        XCTAssertEqual(Set(notifications), Set([firstID, secondID]))
        XCTAssertEqual(notifications.count, 2)
        for meeting in meetings {
            let state = MeetingOutcomeStore.loadState(from: meeting.folderURL(in: storage))
            XCTAssertEqual(state.actions.values.first?.status, .done)
        }
    }

    private func reference(
        meetingID: UUID,
        meetingTitle: String,
        startedAt: Date,
        text: String,
        owner: String = "Me",
        due: String? = nil,
        correctedText: String? = nil,
        correctedDue: String? = nil,
        status: OutcomeStatus = .open,
        stateUpdatedAt: Date? = nil
    ) -> OutcomeActionReference {
        let action = MeetingOutcomes.ActionItem(
            text: text,
            owner: owner,
            due: due,
            citations: [.init(
                meetingID: meetingID,
                segmentID: "segment-\(meetingID.uuidString)",
                start: 1,
                end: 2,
                speaker: owner,
                excerpt: text)])
        return OutcomeActionReference(
            meetingID: meetingID,
            meetingTitle: meetingTitle,
            meetingStartedAt: startedAt,
            action: action,
            status: status,
            text: correctedText ?? action.displayText,
            owner: owner,
            due: correctedDue ?? due,
            stateUpdatedAt: stateUpdatedAt ?? startedAt.addingTimeInterval(30),
            textWasCorrected: correctedText != nil,
            ownerWasCorrected: false,
            dueWasCorrected: correctedDue != nil)
    }
}
