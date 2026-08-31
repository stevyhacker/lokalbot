import XCTest
@testable import LokalBot

extension DreamingTests {
    // MARK: - Headless flag

    func testHeadlessDreamFlagParsesOptionalDay() {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--dream"]),
                       .dream(dayKey: nil))
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--dream", "2026-07-18"]),
                       .dream(dayKey: "2026-07-18"))
        // A following flag is not a day key.
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--dream", "--verbose"]),
                       .dream(dayKey: nil))
    }

    func testHeadlessDigestFlagParsesOptionalDay() {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--digest"]),
                       .digest(dayKey: nil))
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--digest", "2026-08-04"]),
                       .digest(dayKey: "2026-08-04"))
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--digest", "--verbose"]),
                       .digest(dayKey: nil))
    }

    func testHeadlessDreamTargetDefaultsToYesterdayAndAcceptsOlderDays() throws {
        let now = try date("2026-07-20T12:00:00Z")
        let defaultTarget = try HeadlessCommand.validatedDreamTarget(
            dayKey: nil,
            now: now,
            calendar: calendar)
        XCTAssertEqual(defaultTarget.dayKey, "2026-07-19")

        let historicalTarget = try HeadlessCommand.validatedDreamTarget(
            dayKey: "2026-07-18",
            now: now,
            calendar: calendar)
        XCTAssertEqual(historicalTarget.dayKey, "2026-07-18")
    }

    func testHeadlessDreamTargetRejectsCurrentAndFutureDays() throws {
        let now = try date("2026-07-20T12:00:00Z")
        for dayKey in ["2026-07-20", "2026-07-21"] {
            XCTAssertThrowsError(try HeadlessCommand.validatedDreamTarget(
                dayKey: dayKey,
                now: now,
                calendar: calendar)) { error in
                    XCTAssertEqual(error as? DreamDayArgumentError, .notHistorical(dayKey))
                }
        }
    }

    func testHeadlessDreamTargetRejectsNonCanonicalDay() throws {
        XCTAssertThrowsError(try HeadlessCommand.validatedDreamTarget(
            dayKey: "2026-7-18",
            now: try date("2026-07-20T12:00:00Z"),
            calendar: calendar)) { error in
                XCTAssertEqual(error as? DreamDayArgumentError, .invalidFormat("2026-7-18"))
            }
    }

    // MARK: - Redaction

    func testRedactionScrubsCredentialsFromReportAndMemory() throws {
        let apiKey = "sk-" + "abcdef1234567890abcd"
        let githubToken = "ghp_" + "0123456789abcdefghij"
        let report = DreamReport(
            day: "2026-07-18",
            generatedAt: try date("2026-07-19T04:01:00Z"),
            engineName: "Built-in — Test",
            narrative: "Saw password: hunter2secret in a screenshot.",
            topActions: ["Rotate api_key = \(apiKey)"]).redacted()
        XCTAssertFalse(report.narrative.contains("hunter2secret"))
        XCTAssertTrue(report.narrative.contains("[REDACTED]"))
        XCTAssertFalse(try XCTUnwrap(report.topActions.first).contains("sk-" + "abcdef"))

        let memory = DreamMemory(
            updatedAt: try date("2026-07-19T04:01:00Z"),
            activeProjects: [.init(name: "Atlas", status: "token \(githubToken) noted",
                                   lastActiveDay: "2026-07-18", evidence: [])]).redacted()
        XCTAssertFalse(try XCTUnwrap(memory.activeProjects.first).status.contains("ghp_"))
    }
}
