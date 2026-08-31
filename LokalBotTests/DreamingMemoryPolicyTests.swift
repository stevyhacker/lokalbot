import XCTest
@testable import LokalBot

final class DreamingMemoryPolicyTests: XCTestCase {
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

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dreaming-policy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testExpiredGoalIsRemovedAndNeverInserted() throws {
        let existing = DreamMemory(
            updatedAt: try date("2026-07-18T04:00:00Z"),
            workGoals: [
                .init(text: "Ship 0.5", horizon: "next week",
                      lastReinforcedDay: "2026-07-17"),
                .init(text: "Keep inbox at zero", horizon: "ongoing",
                      lastReinforcedDay: "2026-07-17"),
            ])
        let update = DreamMemoryUpdate(workGoals: [
            .init(text: "ship 0.5", horizon: "done",
                  reinforcedToday: true, expired: true),
            .init(text: "Never existed", horizon: "unknown",
                  reinforcedToday: true, expired: true),
        ])

        let merged = existing.merging(update, dreamDay: "2026-07-18",
                                      at: try date("2026-07-19T04:01:00Z"),
                                      calendar: calendar)

        XCTAssertEqual(merged.workGoals.map(\.text), ["Keep inbox at zero"])
    }

    func testParseReadsOptionalExpiredFlag() throws {
        let output = """
        {"narrative": "Wrapped up the release.", "attention": [], "repeated_work": [],
         "suggested_checks": [], "frictions": [], "top_actions": [],
         "active_projects": [],
         "work_goals": [
            {"text": "Ship 0.5", "horizon": "done", "reinforced_today": true, "expired": true},
            {"text": "Plan 0.6", "horizon": "next month", "reinforced_today": true}],
         "recurring_patterns": []}
        """
        let synthesis = try XCTUnwrap(DreamPrompts.parse(output))
        XCTAssertEqual(synthesis.memory.workGoals.map(\.expired), [true, false])
    }

    func testSystemPromptAndStrictSchemaRequireExpiredGoals() throws {
        XCTAssertTrue(DreamPrompts.system.contains("expired"))

        let properties = try XCTUnwrap(DreamPrompts.schema["properties"]?.objectValue)
        let goals = try XCTUnwrap(properties["work_goals"]?.objectValue)
        let items = try XCTUnwrap(goals["items"]?.objectValue)
        let goalProperties = try XCTUnwrap(items["properties"]?.objectValue)
        XCTAssertNotNil(goalProperties["expired"])
        let required = try XCTUnwrap(items["required"]?.stringArrayValue)
        XCTAssertTrue(required.contains("expired"))
    }

    func testPinnedEntriesSurviveRetentionCapsAndExpiry() throws {
        let existing = DreamMemory(
            updatedAt: try date("2026-07-18T04:00:00Z"),
            activeProjects: [.init(name: "Anchor", status: "long-running",
                                   lastActiveDay: "2026-01-01", evidence: [],
                                   pinned: true)],
            workGoals: [.init(text: "North star", horizon: "always",
                              lastReinforcedDay: "2026-01-01", pinned: true)])
        var update = DreamMemoryUpdate(
            activeProjects: (1...DreamMemory.maxProjects).map {
                .init(name: "Project \($0)", status: "active", evidence: [])
            },
            workGoals: (1...DreamMemory.maxGoals).map {
                .init(text: "Goal \($0)", horizon: "soon", reinforcedToday: true)
            })
        update.workGoals.append(.init(text: "North star", horizon: "gone",
                                      reinforcedToday: true, expired: true))

        let merged = existing.merging(update, dreamDay: "2026-07-18",
                                      at: try date("2026-07-19T04:01:00Z"),
                                      calendar: calendar)

        XCTAssertTrue(merged.activeProjects.contains { $0.name == "Anchor" })
        XCTAssertTrue(merged.workGoals.contains { $0.text == "North star" })
        XCTAssertLessThanOrEqual(merged.activeProjects.count, DreamMemory.maxProjects)
        XCTAssertLessThanOrEqual(merged.workGoals.count, DreamMemory.maxGoals)
    }

    func testLegacyMemoryFilesWithoutPinnedKeyStillDecode() throws {
        let legacy = Data("""
        {"version": 1, "updatedAt": "2026-07-19T04:01:00Z", "lastDreamDay": "2026-07-18",
         "activeProjects": [{"name": "Atlas", "status": "in review",
                             "lastActiveDay": "2026-07-18", "evidence": []}],
         "workGoals": [{"text": "Ship 0.5", "horizon": "next week",
                        "lastReinforcedDay": "2026-07-18"}],
         "recurringPatterns": []}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let memory = try decoder.decode(DreamMemory.self, from: legacy)
        XCTAssertEqual(memory.activeProjects.first?.pinned, false)
        XCTAssertEqual(memory.workGoals.first?.pinned, false)
    }

    func testMarkdownMarksPinnedEntries() throws {
        let memory = DreamMemory(
            updatedAt: try date("2026-07-19T04:01:00Z"),
            activeProjects: [.init(name: "Anchor", status: "long-running",
                                   lastActiveDay: "2026-07-18", evidence: [],
                                   pinned: true)],
            workGoals: [.init(text: "North star", horizon: "always",
                              lastReinforcedDay: "2026-07-18", pinned: true)])
        let markdown = memory.markdown()
        let pinMentions = markdown.components(separatedBy: "pinned").count - 1
        XCTAssertEqual(pinMentions, 2)
    }

    func testStorePersistsProjectAndGoalPins() throws {
        let store = DreamStore(root: try temporaryRoot())
        let initial = DreamMemory(
            updatedAt: try date("2026-07-19T04:01:00Z"),
            activeProjects: [.init(name: "Anchor", status: "long-running",
                                   lastActiveDay: "2026-07-18")],
            workGoals: [.init(text: "North star", horizon: "always",
                              lastReinforcedDay: "2026-07-18")])
        try store.save(initial)

        let projectUpdate = try XCTUnwrap(store.setPinned(
            true,
            for: .project(name: "anchor"),
            at: try date("2026-07-19T05:00:00Z")))
        XCTAssertTrue(try XCTUnwrap(projectUpdate.activeProjects.first).pinned)

        let goalUpdate = try XCTUnwrap(store.setPinned(
            true,
            for: .goal(text: "north star"),
            at: try date("2026-07-19T05:01:00Z")))
        XCTAssertTrue(try XCTUnwrap(goalUpdate.workGoals.first).pinned)

        let reloaded = try XCTUnwrap(store.loadMemory())
        XCTAssertTrue(try XCTUnwrap(reloaded.activeProjects.first).pinned)
        XCTAssertTrue(try XCTUnwrap(reloaded.workGoals.first).pinned)
        XCTAssertEqual(reloaded.updatedAt, try date("2026-07-19T05:01:00Z"))
    }

    func testDreamingRequiresACPowerAndNormalPowerMode() {
        XCTAssertTrue(DreamScheduler.powerAllowsDreaming(
            isOnBattery: false, isLowPower: false))
        XCTAssertFalse(DreamScheduler.powerAllowsDreaming(
            isOnBattery: true, isLowPower: false))
        XCTAssertFalse(DreamScheduler.powerAllowsDreaming(
            isOnBattery: false, isLowPower: true))
    }
}
