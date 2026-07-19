import XCTest
@testable import LokalBot

final class DreamingTests: XCTestCase {
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
            .appendingPathComponent("dreaming-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func sampleEvidence() throws -> DreamEvidence {
        var outcomes = MeetingOutcomes()
        outcomes.actionItems = [
            .init(text: "Send the launch checklist", owner: "Me", due: "Friday"),
            .init(text: "Review the appcast", owner: "Ana"),
        ]
        outcomes.decisions = ["Ship 0.5 next week"]
        outcomes.openQuestions = ["Who owns the release notes?"]
        return DreamEvidence(
            day: try date("2026-07-18T00:00:00Z"),
            dayKey: "2026-07-18",
            digest: "## What I worked on\n- Release prep",
            meetings: [.init(
                shortID: "abcd1234",
                title: "Release sync",
                durationLabel: "42 min",
                startedAt: try date("2026-07-18T09:00:00Z"),
                outcomes: outcomes)],
            appUsage: [],
            stats: ScreenMemoryDaySummary(
                trackedSeconds: 4 * 3600,
                appCount: 6,
                activityBlockCount: 12,
                screenshotCount: 30,
                savedMomentCount: 1),
            savedMoments: [],
            priorMeetings: [.init(dayKey: "2026-07-17", title: "Release sync")],
            openActions: ["- [ ] Fix flaky UI test — `98761234`"])
    }

    // MARK: - Scheduler

    func testShouldRunWaitsForHourAndSkipsDreamedDays() throws {
        XCTAssertFalse(DreamScheduler.shouldRun(
            at: try date("2026-07-19T03:59:00Z"), hour: 4,
            hasReportForPreviousDay: false, calendar: calendar))
        XCTAssertTrue(DreamScheduler.shouldRun(
            at: try date("2026-07-19T04:00:00Z"), hour: 4,
            hasReportForPreviousDay: false, calendar: calendar))
        XCTAssertTrue(DreamScheduler.shouldRun(
            at: try date("2026-07-19T09:30:00Z"), hour: 4,
            hasReportForPreviousDay: false, calendar: calendar))
        XCTAssertFalse(DreamScheduler.shouldRun(
            at: try date("2026-07-19T09:30:00Z"), hour: 4,
            hasReportForPreviousDay: true, calendar: calendar))
        // Defensive hour clamp: 99 behaves as 23, not as "always due".
        XCTAssertFalse(DreamScheduler.shouldRun(
            at: try date("2026-07-19T12:00:00Z"), hour: 99,
            hasReportForPreviousDay: false, calendar: calendar))
    }

    func testPreviousDayCrossesMonthBoundary() throws {
        XCTAssertEqual(
            DreamScheduler.previousDay(of: try date("2026-07-01T10:15:00Z"),
                                       calendar: calendar),
            try date("2026-06-30T00:00:00Z"))
    }

    @MainActor
    func testStopCancelsInFlightDream() async throws {
        let current = try date("2026-07-19T04:00:00Z")
        let scheduler = DreamScheduler(calendar: calendar, now: { current })
        let started = expectation(description: "dream started")
        let cancelled = expectation(description: "dream cancelled")
        let reportedError = expectation(description: "cancellation reported as error")
        reportedError.isInverted = true

        scheduler.configure(
            .init(enabled: true, hour: 4),
            hasReport: { _ in false },
            canRun: { true },
            dream: { _ in
                started.fulfill()
                do {
                    while true { try await Task.sleep(for: .seconds(60)) }
                } catch is CancellationError {
                    cancelled.fulfill()
                    throw CancellationError()
                }
            },
            onError: { _ in reportedError.fulfill() })

        await fulfillment(of: [started], timeout: 5)
        scheduler.stop()
        await fulfillment(of: [cancelled], timeout: 5)
        await fulfillment(of: [reportedError], timeout: 0.5)
        XCTAssertFalse(scheduler.isDreaming)
    }

    // MARK: - Store

    func testStoreRoundTripPermissionsAndLatest() throws {
        let root = try temporaryRoot()
        let store = DreamStore(root: root)
        let report = DreamReport(
            day: "2026-07-18",
            generatedAt: try date("2026-07-19T04:01:00Z"),
            engineName: "Built-in — Test",
            narrative: "A focused day.",
            attention: ["CI is red — `abcd1234`"],
            topActions: ["Fix CI first"])
        XCTAssertFalse(store.hasReport(forDayKey: "2026-07-18"))
        try store.save(report)
        XCTAssertTrue(store.hasReport(forDayKey: "2026-07-18"))
        XCTAssertEqual(store.report(forDayKey: "2026-07-18"), report)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: store.reportJSONURL(forDayKey: "2026-07-18").path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o777, 0o600)

        var newer = report
        newer.day = "2026-07-19"
        try store.save(newer)
        XCTAssertEqual(store.latestReport()?.day, "2026-07-19")

        let memory = DreamMemory(
            updatedAt: try date("2026-07-19T04:01:00Z"),
            lastDreamDay: "2026-07-18",
            activeProjects: [.init(name: "Atlas", status: "in review",
                                   lastActiveDay: "2026-07-18", evidence: ["`abcd1234`"])])
        XCTAssertNil(store.loadMemory())
        try store.save(memory)
        XCTAssertEqual(store.loadMemory(), memory)

        let markdown = try String(
            contentsOf: store.dreamsDirectory.appendingPathComponent("2026-07-18.md"),
            encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix(DreamStore.generatedMarker))
        XCTAssertTrue(markdown.contains("Morning brief — 2026-07-18"))
    }

    // MARK: - Prompts / parsing

    func testParseToleratesFencedJSONAndAppliesCaps() throws {
        let output = """
        Sure! Here is the retrospective:
        ```json
        {"narrative": "Busy release day.",
         "attention": ["CI red on lokalbot — `abcd1234`"],
         "repeated_work": [], "suggested_checks": [], "frictions": [],
         "top_actions": ["Fix CI", "Merge the PR", "Draft notes", "Extra item"],
         "active_projects": [{"name": "Atlas", "status": "in review",
                              "evidence": ["`abcd1234`", "e2", "e3", "e4", "e5"]}],
         "work_goals": [{"text": "Ship 0.5", "horizon": "next week"}],
         "recurring_patterns": ["Mornings go to review"]}
        ```
        """
        let synthesis = try XCTUnwrap(DreamPrompts.parse(output))
        XCTAssertEqual(synthesis.narrative, "Busy release day.")
        XCTAssertEqual(synthesis.attention, ["CI red on lokalbot — `abcd1234`"])
        XCTAssertEqual(synthesis.topActions.count, DreamPrompts.maxTopActions)
        XCTAssertEqual(synthesis.memory.activeProjects.first?.name, "Atlas")
        XCTAssertEqual(synthesis.memory.activeProjects.first?.evidence.count,
                       DreamMemory.maxEvidencePerProject)
        XCTAssertEqual(synthesis.memory.workGoals,
                       [.init(text: "Ship 0.5", horizon: "next week")])
    }

    func testParseRejectsUnusableOutput() {
        XCTAssertNil(DreamPrompts.parse("I could not find anything to analyze."))
        XCTAssertNil(DreamPrompts.parse("""
        {"narrative": "", "attention": [], "repeated_work": [], "suggested_checks": [],
         "frictions": [], "top_actions": [], "active_projects": [], "work_goals": [],
         "recurring_patterns": []}
        """))
    }

    // MARK: - Fallback compilation

    func testFallbackReportIsEvidenceOnlyAndDeterministic() throws {
        let evidence = try sampleEvidence()
        let generatedAt = try date("2026-07-19T04:01:00Z")
        let report = DreamCompiler.fallbackReport(
            from: evidence, generatedAt: generatedAt, note: "No model.")
        XCTAssertNil(report.engineName)
        XCTAssertTrue(report.isFallback)
        XCTAssertEqual(report.day, "2026-07-18")
        XCTAssertTrue(report.narrative.contains("1 recorded meeting"))
        XCTAssertTrue(report.narrative.contains("4h 0m"))
        XCTAssertEqual(report.attention,
                       ["Who owns the release notes? — `abcd1234`"])
        // The user's own commitment leads; analysis sections stay empty
        // because the fallback never infers.
        XCTAssertEqual(report.topActions.count, 1)
        XCTAssertTrue(try XCTUnwrap(report.topActions.first)
            .contains("Send the launch checklist"))
        XCTAssertTrue(report.repeatedWork.isEmpty)
        XCTAssertTrue(report.suggestedChecks.isEmpty)
        XCTAssertTrue(report.frictions.isEmpty)
        XCTAssertEqual(
            report,
            DreamCompiler.fallbackReport(from: evidence, generatedAt: generatedAt,
                                         note: "No model."))
    }

    func testEvidencePackCitesMeetingsAndKeepsWindowLabeled() throws {
        let pack = DreamCompiler.evidencePack(try sampleEvidence())
        XCTAssertTrue(pack.contains("Release sync (`abcd1234`, 42 min)"))
        XCTAssertTrue(pack.contains("decision: Ship 0.5 next week"))
        XCTAssertTrue(pack.contains("comparison window only"))
        XCTAssertTrue(pack.contains("completion is unknown"))
        XCTAssertLessThanOrEqual(pack.count, DreamCompiler.evidenceCharacterLimit)
    }

    // MARK: - Memory merge

    func testMemoryMergeInsertsUpdatesPrunesAndKeepsUnchangedStamps() throws {
        let existing = DreamMemory(
            updatedAt: try date("2026-07-18T04:00:00Z"),
            lastDreamDay: "2026-07-17",
            activeProjects: [
                .init(name: "Atlas", status: "waiting on review",
                      lastActiveDay: "2026-07-17", evidence: ["PR open"]),
                .init(name: "Steady", status: "background refactor",
                      lastActiveDay: "2026-07-16", evidence: []),
                .init(name: "Dusty", status: "paused",
                      lastActiveDay: "2026-05-01", evidence: []),
            ],
            workGoals: [.init(text: "Ship 0.5", horizon: "Q3",
                              lastReinforcedDay: "2026-07-10")],
            recurringPatterns: ["Mornings go to email"])
        let update = DreamMemoryUpdate(
            activeProjects: [
                .init(name: "atlas", status: "merged, awaiting release",
                      evidence: ["`abcd1234`"]),
                .init(name: "Steady", status: "background refactor", evidence: []),
                .init(name: "Beacon", status: "kickoff scheduled", evidence: []),
            ],
            workGoals: [.init(text: "ship 0.5", horizon: "next week")],
            recurringPatterns: ["Deep work lands after 15:00"])

        let merged = existing.merging(update, dreamDay: "2026-07-18",
                                      at: try date("2026-07-19T04:01:00Z"),
                                      calendar: calendar)

        XCTAssertEqual(merged.lastDreamDay, "2026-07-18")
        let names = merged.activeProjects.map(\.name)
        XCTAssertTrue(names.contains("Atlas"))
        XCTAssertTrue(names.contains("Beacon"))
        XCTAssertTrue(names.contains("Steady"))
        // Untouched for 78 days — aged out.
        XCTAssertFalse(names.contains("Dusty"))

        let atlas = try XCTUnwrap(merged.activeProjects.first { $0.name == "Atlas" })
        XCTAssertEqual(atlas.status, "merged, awaiting release")
        XCTAssertEqual(atlas.lastActiveDay, "2026-07-18")
        // Proposed identically → not "activity"; the stamp must not refresh.
        let steady = try XCTUnwrap(merged.activeProjects.first { $0.name == "Steady" })
        XCTAssertEqual(steady.lastActiveDay, "2026-07-16")

        XCTAssertEqual(merged.workGoals.count, 1)
        XCTAssertEqual(merged.workGoals.first?.lastReinforcedDay, "2026-07-18")
        XCTAssertEqual(merged.workGoals.first?.horizon, "next week")
        XCTAssertEqual(merged.recurringPatterns, ["Deep work lands after 15:00"])

        // An empty pattern proposal keeps the previous patterns.
        let unchanged = merged.merging(DreamMemoryUpdate(), dreamDay: "2026-07-19",
                                       at: try date("2026-07-20T04:01:00Z"),
                                       calendar: calendar)
        XCTAssertEqual(unchanged.recurringPatterns, ["Deep work lands after 15:00"])
    }

    // MARK: - Redaction

    func testRedactionScrubsCredentialsFromReportAndMemory() throws {
        let report = DreamReport(
            day: "2026-07-18",
            generatedAt: try date("2026-07-19T04:01:00Z"),
            engineName: "Built-in — Test",
            narrative: "Saw password: hunter2secret in a screenshot.",
            topActions: ["Rotate api_key = sk-abcdef1234567890abcd"]).redacted()
        XCTAssertFalse(report.narrative.contains("hunter2secret"))
        XCTAssertTrue(report.narrative.contains("[REDACTED]"))
        XCTAssertFalse(try XCTUnwrap(report.topActions.first).contains("sk-abcdef"))

        let memory = DreamMemory(
            updatedAt: try date("2026-07-19T04:01:00Z"),
            activeProjects: [.init(name: "Atlas", status: "token ghp_0123456789abcdefghij noted",
                                   lastActiveDay: "2026-07-18", evidence: [])]).redacted()
        XCTAssertFalse(try XCTUnwrap(memory.activeProjects.first).status.contains("ghp_"))
    }
}
