import XCTest
@testable import LokalBot

final class DailyEvidenceSnapshotTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testSnapshotAppliesOverlayAndRejectsStaleDigest() throws {
        let root = try temporaryRoot()
        let day = try date("2026-07-18T12:00:00Z")
        let meetingID = UUID()
        try MeetingFixture.write([
            .init(
                id: meetingID,
                title: "Release review",
                startedAt: try date("2026-07-18T09:00:00Z"),
                summary: "Reviewed the launch plan."),
        ], under: root)
        let storage = StorageManager(rootURL: root)
        let meeting = try XCTUnwrap(SessionLookup.loadAllMeetings(root: root).first)
        let done = MeetingOutcomes.ActionItem(text: "Publish old draft", owner: "Me")
        let corrected = MeetingOutcomes.ActionItem(text: "Publish draft", owner: "Me")
        try MeetingOutcomes(
            actionItems: [done, corrected],
            decisions: ["Ship Tuesday"]).write(to: meeting.folderURL(in: storage))
        let artifactDate = try date("2026-07-18T17:00:00Z")
        for artifact in ["summary.md", MeetingOutcomes.fileName] {
            try FileManager.default.setAttributes(
                [.modificationDate: artifactDate],
                ofItemAtPath: meeting.folderURL(in: storage)
                    .appendingPathComponent(artifact).path)
        }

        let journal = root.appendingPathComponent("journal/2026-07-18.md")
        try FileManager.default.createDirectory(
            at: journal.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "Stale digest says publish both drafts.".write(
            to: journal,
            atomically: true,
            encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: try date("2026-07-18T18:00:00Z")],
            ofItemAtPath: journal.path)

        var state = MeetingOutcomeState()
        state.actions[done.id] = .init(
            status: .done,
            updatedAt: try date("2026-07-18T18:05:00Z"),
            userEdited: true)
        state.actions[corrected.id] = .init(
            dueOverride: "Tuesday",
            textCorrection: "Publish the verified draft",
            updatedAt: try date("2026-07-18T18:05:00Z"),
            userEdited: true)
        try MeetingOutcomeStore.writeState(state, to: meeting.folderURL(in: storage))
        let stateURL = meeting.folderURL(in: storage)
            .appendingPathComponent(MeetingOutcomeState.fileName)
        try FileManager.default.setAttributes(
            [.modificationDate: try date("2026-07-18T18:05:00Z")],
            ofItemAtPath: stateURL.path)

        let snapshot = try FileDailyEvidenceSource(
            root: root,
            calendar: calendar).snapshot(
            for: day,
            meetings: [meeting],
            includeDetailedActivity: false)
        let evidence = try XCTUnwrap(snapshot.meetings.first)

        XCTAssertEqual(evidence.summary, "Reviewed the launch plan.")
        XCTAssertEqual(evidence.activeActionReferences.map(\.text), ["Publish the verified draft"])
        XCTAssertEqual(evidence.activeActionReferences.first?.due, "Tuesday")
        XCTAssertEqual(evidence.activeOutcomes.actionItems.map(\.text), ["Publish the verified draft"])
        XCTAssertEqual(snapshot.latestEvidenceAt, try date("2026-07-18T18:05:00Z"))
        XCTAssertNil(DailyEvidenceArtifacts.currentDigest(
            for: snapshot,
            root: root,
            calendar: calendar))
    }

    func testSignatureChangesWithUserCorrection() throws {
        let root = try temporaryRoot()
        let startedAt = try date("2026-07-18T09:00:00Z")
        try MeetingFixture.write([
            .init(title: "Planning", startedAt: startedAt),
        ], under: root)
        let storage = StorageManager(rootURL: root)
        let meeting = try XCTUnwrap(SessionLookup.loadAllMeetings(root: root).first)
        let action = MeetingOutcomes.ActionItem(text: "Send the plan", owner: "Me")
        try MeetingOutcomes(actionItems: [action]).write(to: meeting.folderURL(in: storage))
        let source = FileDailyEvidenceSource(root: root, calendar: calendar)
        let before = try source.snapshot(
            for: startedAt,
            meetings: [meeting],
            includeDetailedActivity: false)

        var state = MeetingOutcomeState()
        state.actions[action.id] = .init(
            dueOverride: "Friday",
            textCorrection: "Send the verified plan",
            updatedAt: startedAt.addingTimeInterval(600),
            userEdited: true)
        try MeetingOutcomeStore.writeState(state, to: meeting.folderURL(in: storage))
        let after = try source.snapshot(
            for: startedAt,
            meetings: [meeting],
            includeDetailedActivity: false)

        XCTAssertNotEqual(before.signature, after.signature)
        XCTAssertEqual(after.meetings.first?.activeActionReferences.first?.text,
                       "Send the verified plan")
    }

    func testFullSnapshotToleratesDatabaseBeforeSchemaCreation() throws {
        let root = try temporaryRoot()
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("lokalbotv3.sqlite").path,
            contents: Data())

        let snapshot = try FileDailyEvidenceSource(
            root: root,
            calendar: calendar).snapshot(for: try date("2026-07-18T12:00:00Z"))

        XCTAssertEqual(snapshot.coverage, .all)
        XCTAssertTrue(snapshot.activityBlocks.isEmpty)
        XCTAssertTrue(snapshot.screenContexts.isEmpty)
        XCTAssertEqual(snapshot.stats.trackedSeconds, 0)
    }

    func testDreamUsesCorrectedActiveThreadsAndExcludesCompletedActions() throws {
        let root = try temporaryRoot()
        let firstID = UUID()
        let secondID = UUID()
        let firstDate = try date("2026-07-17T09:00:00Z")
        let secondDate = try date("2026-07-18T09:00:00Z")
        try MeetingFixture.write([
            .init(id: firstID, title: "Planning", startedAt: firstDate),
            .init(id: secondID, title: "Review", startedAt: secondDate),
        ], under: root)
        let storage = StorageManager(rootURL: root)
        let meetings = try SessionLookup.loadAllMeetings(root: root)
        for meeting in meetings {
            let repeated = MeetingOutcomes.ActionItem(
                text: "Send the revised launch proposal",
                owner: "Me")
            let obsolete = MeetingOutcomes.ActionItem(
                text: "Publish obsolete checklist",
                owner: "Me")
            try MeetingOutcomes(actionItems: [repeated, obsolete])
                .write(to: meeting.folderURL(in: storage))
            var state = MeetingOutcomeState()
            state.actions[obsolete.id] = .init(status: .done, userEdited: true)
            if meeting.id == secondID {
                state.actions[repeated.id] = .init(
                    textCorrection: "Send Acme the revised launch proposal",
                    userEdited: true)
            }
            try MeetingOutcomeStore.writeState(state, to: meeting.folderURL(in: storage))
        }

        let evidence = try DreamCompiler.compile(
            day: secondDate,
            storageRoot: root,
            calendar: calendar)

        XCTAssertEqual(evidence.openActions.count, 1)
        XCTAssertTrue(evidence.openActions[0].contains("Send Acme the revised launch proposal"))
        XCTAssertTrue(evidence.openActions[0].contains("sources:"))
        XCTAssertFalse(evidence.openActions[0].contains("obsolete"))
        XCTAssertFalse(evidence.meetings.flatMap { $0.outcomes.actionItems }
            .contains(where: { $0.text.contains("obsolete") }))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }
}
