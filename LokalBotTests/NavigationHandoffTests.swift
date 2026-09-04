import XCTest
@testable import LokalBot

@MainActor
final class NavigationHandoffTests: XCTestCase {
    func testAskHandoffIsAtomicLatestWinsAndConsumesOnce() {
        let handoff = NavigationHandoff()
        let day = Date(timeIntervalSince1970: 1_700_000_000)

        handoff.stageAsk(
            query: "first",
            dayScope: nil,
            screenSnapshotIDs: [1],
            submit: false)
        handoff.stageAsk(
            query: "second",
            dayScope: day,
            screenSnapshotIDs: [2, 3],
            submit: true)

        XCTAssertEqual(
            handoff.consumeAsk(),
            AskNavigationHandoff(
                query: "second",
                dayScope: day,
                screenSnapshotIDs: [2, 3],
                submit: true))
        XCTAssertNil(handoff.consumeAsk())
    }

    func testMeetingSeekOnlyMatchesItsDestination() {
        let handoff = NavigationHandoff()
        let expectedMeetingID = UUID()

        handoff.stageMeeting(expectedMeetingID, seek: 42)

        XCTAssertNil(handoff.consumeMeetingSeek(for: UUID()))
        XCTAssertEqual(handoff.consumeMeetingSeek(for: expectedMeetingID), 42)
        XCTAssertNil(handoff.consumeMeetingSeek(for: expectedMeetingID))
    }

    func testEvidenceDefaultsToRevealAndExplicitPlayIsPreserved() {
        let handoff = NavigationHandoff()
        let meetingID = UUID()
        handoff.stageMeeting(meetingID, seek: 42)
        XCTAssertEqual(handoff.consumeMeetingEvidence(for: meetingID)?.intent, .reveal)
        handoff.stageMeeting(meetingID, seek: 42, intent: .play)
        XCTAssertEqual(handoff.consumeMeetingEvidence(for: meetingID)?.intent, .play)
    }

    func testOpeningMeetingWithoutSeekClearsOlderRequest() {
        let handoff = NavigationHandoff()
        let meetingID = UUID()

        handoff.stageMeeting(meetingID, seek: 42)
        handoff.stageMeeting(meetingID, seek: nil)

        XCTAssertNil(handoff.consumeMeetingSeek(for: meetingID))
    }

    func testDestinationPayloadsCanCoexist() {
        let handoff = NavigationHandoff()
        let context = AgentLaunchContext(
            title: "Prepare follow-up",
            prompt: "Draft the note",
            meetingID: UUID(),
            actionID: "action-1")

        handoff.stageAsk(
            query: "roadmap",
            dayScope: nil,
            screenSnapshotIDs: [],
            submit: false)
        handoff.stageScreenSnapshot(77)
        handoff.stageAgent(context)

        XCTAssertEqual(handoff.consumeScreenSnapshot(), 77)
        XCTAssertEqual(handoff.consumeAsk()?.query, "roadmap")
        XCTAssertEqual(handoff.agentContext, context)
        XCTAssertEqual(handoff.consumeAgentContext(), context)
        XCTAssertNil(handoff.agentContext)
    }
}
