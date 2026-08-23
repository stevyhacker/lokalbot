import XCTest
@testable import LokalBot

@MainActor
final class DayDigestLifecycleTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }

    func testSnapshotOwnsJournalFreshnessAndLatestEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("day-digest-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try date("2026-08-23T12:00:00Z")
        let journal = root.appendingPathComponent("journal/2026-08-23.md")
        try FileManager.default.createDirectory(
            at: journal.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "## Focus\n\nShipped the lifecycle.".write(
            to: journal,
            atomically: true,
            encoding: .utf8)
        let modifiedAt = try date("2026-08-23T18:00:00Z")
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: journal.path)
        let latestEvidenceAt = try date("2026-08-23T18:30:00Z")

        let lifecycle = makeLifecycle(
            root: root,
            latestActivityEvidenceAt: { _ in latestEvidenceAt })
        let snapshot = lifecycle.snapshot(for: day)

        XCTAssertEqual(snapshot.text, "## Focus\n\nShipped the lifecycle.")
        XCTAssertEqual(snapshot.modifiedAt, modifiedAt)
        XCTAssertEqual(snapshot.latestEvidenceAt, latestEvidenceAt)
        XCTAssertTrue(snapshot.isStale)
    }

    func testGenerateCollectsFinishedDayEvidenceThroughOneInterface() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("day-digest-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try date("2026-08-23T12:00:00Z")
        let finished = Meeting(
            id: UUID(),
            title: "Architecture",
            appName: "Meet",
            startedAt: try date("2026-08-23T09:00:00Z"),
            endedAt: try date("2026-08-23T09:30:00Z"),
            relativePath: "meetings/architecture")
        let inProgress = Meeting(
            id: UUID(),
            title: "Live",
            appName: "Meet",
            startedAt: try date("2026-08-23T11:00:00Z"),
            endedAt: nil,
            relativePath: "meetings/live")
        let block = ActivityBlock(
            id: 7,
            app: "Xcode",
            title: "DayDigestLifecycle.swift",
            start: try date("2026-08-23T10:00:00Z"),
            end: try date("2026-08-23T10:30:00Z"))
        let screen = DayScreenContext(
            snapshotID: 42,
            capturedAt: try date("2026-08-23T10:15:00Z"),
            app: "Xcode",
            windowTitle: "LokalBot",
            text: "Deepen the Day Digest module")
        var receivedBlocks: [ActivityBlock] = []
        var receivedMeetings: [Meeting] = []
        var receivedScreens: [DayScreenContext] = []

        let lifecycle = DayDigestLifecycle(
            storageRoot: root,
            calendar: calendar,
            blocks: { _ in [block] },
            screenContexts: { _ in [screen] },
            meetings: { [finished, inProgress] },
            latestActivityEvidenceAt: { _ in nil },
            settings: AppSettings.init,
            generator: { _, blocks, meetings, screens, _ in
                receivedBlocks = blocks
                receivedMeetings = meetings
                receivedScreens = screens
                return DayDigestGenerationResult(
                    text: "digest",
                    url: root.appendingPathComponent("journal/2026-08-23.md"),
                    quality: .complete)
            })

        _ = try await lifecycle.generate(for: day)

        XCTAssertEqual(receivedBlocks, [block])
        XCTAssertEqual(receivedMeetings, [finished])
        XCTAssertEqual(receivedScreens, [screen])
    }

    func testHeadlessOutputKeepsJournalPathAtStablePosition() throws {
        let day = try date("2026-08-23T12:00:00Z")
        let result = DayDigestGenerationResult(
            text: "## Focus",
            url: URL(fileURLWithPath: "/tmp/journal/2026-08-23.md"),
            quality: .complete)

        let output = DayDigestCLIOutput.render(
            result: result,
            modelID: "qwen",
            day: day)

        XCTAssertTrue(output.hasPrefix(
            "LokalBot --digest: /tmp/journal/2026-08-23.md ("))
        XCTAssertTrue(output.contains("model=qwen"))
        XCTAssertTrue(output.contains("day=2026-08-23"))
    }

    private func makeLifecycle(
        root: URL,
        latestActivityEvidenceAt: @escaping (Date) -> Date?
    ) -> DayDigestLifecycle {
        DayDigestLifecycle(
            storageRoot: root,
            calendar: calendar,
            blocks: { _ in [] },
            screenContexts: { _ in [] },
            meetings: { [] },
            latestActivityEvidenceAt: latestActivityEvidenceAt,
            settings: AppSettings.init,
            generator: { day, _, _, _, _ in
                DayDigestGenerationResult(
                    text: "",
                    url: root.appendingPathComponent(
                        "journal/\(DreamDay.key(for: day)).md"),
                    quality: .complete)
            })
    }
}
