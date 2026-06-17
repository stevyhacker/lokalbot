import XCTest
@testable import BotinaV2

final class UpdateCheckerTests: XCTestCase {
    private func release(tag: String, name: String? = nil, body: String? = nil) -> GitHubRelease {
        GitHubRelease(tagName: tag, name: name, body: body, htmlURL: "https://example.com/r")
    }

    // MARK: - evaluate

    func testEvaluateUpdateAvailable() {
        let outcome = UpdateChecker.evaluate(currentVersion: "0.1.0", release: release(tag: "v0.2.0"))
        guard case .updateAvailable(_, let latest) = outcome else {
            return XCTFail("expected updateAvailable, got \(outcome)")
        }
        XCTAssertEqual(latest.description, "0.2.0")
    }

    func testEvaluateUpToDate() {
        let outcome = UpdateChecker.evaluate(currentVersion: "1.0.0", release: release(tag: "v1.0.0"))
        guard case .upToDate(let current) = outcome else {
            return XCTFail("expected upToDate, got \(outcome)")
        }
        XCTAssertEqual(current.description, "1.0.0")
    }

    func testEvaluateGarbledTagReportsUpToDate() {
        let outcome = UpdateChecker.evaluate(currentVersion: "1.0.0",
                                             release: release(tag: "release-day"))
        if case .upToDate = outcome {} else { XCTFail("expected upToDate for unparseable tag") }
    }

    func testEvaluateGarbledCurrentVersionReportsUpToDate() {
        // Defensive: never claim "update available" if we can't parse our own version.
        let outcome = UpdateChecker.evaluate(currentVersion: "not-a-version",
                                             release: release(tag: "v9.9.9"))
        if case .upToDate = outcome {} else { XCTFail("expected upToDate for unparseable current") }
    }

    // MARK: - releaseNotesSummary

    func testReleaseNotesStripsTitleAndBoilerplate() {
        let body = """
        # BotinaV2 0.2.0

        - Faster recording start
        - Fewer audio glitches

        ## Installing
        Drag to /Applications.
        """
        let summary = UpdateChecker.releaseNotesSummary(body)
        XCTAssertEqual(summary, """
        - Faster recording start
        - Fewer audio glitches
        """)
    }

    func testReleaseNotesStopsAtHorizontalRule() {
        let body = """
        - feature one

        ---

        Full changelog: …
        """
        XCTAssertEqual(UpdateChecker.releaseNotesSummary(body), "- feature one")
    }

    func testReleaseNotesNilForEmpty() {
        XCTAssertNil(UpdateChecker.releaseNotesSummary(nil))
        XCTAssertNil(UpdateChecker.releaseNotesSummary("   \n  "))
    }

    // MARK: - displayName

    func testDisplayNameFavorsReleaseName() {
        XCTAssertEqual(UpdateChecker.displayName(for: release(tag: "v0.2.0", name: "0.2 — Recording fixes")),
                       "0.2 — Recording fixes")
    }

    func testDisplayNameFallsBackToTag() {
        XCTAssertEqual(UpdateChecker.displayName(for: release(tag: "v0.2.0")),
                       "Version 0.2.0")
    }

    // MARK: - UpdateSettings.isDue

    func testIsDueWhenNeverChecked() {
        XCTAssertTrue(UpdateSettings.isDue(lastCheck: nil, now: Date()))
    }

    func testIsDueAfterInterval() {
        let now = Date()
        let yesterday = now.addingTimeInterval(-25 * 60 * 60)
        XCTAssertTrue(UpdateSettings.isDue(lastCheck: yesterday, now: now))
    }

    func testNotDueWithinInterval() {
        let now = Date()
        let hourAgo = now.addingTimeInterval(-60 * 60)
        XCTAssertFalse(UpdateSettings.isDue(lastCheck: hourAgo, now: now))
    }
}
