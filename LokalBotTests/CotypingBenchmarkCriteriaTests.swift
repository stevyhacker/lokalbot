import AppKit
import XCTest
@testable import LokalBot

// MARK: - Benchmark word-completion pass criteria (Cotypist parity)

final class CotypingBenchmarkCriteriaTests: XCTestCase {
    private func scenario(
        allowedSuppressions: [CotypingSuppressionReason] = [],
        expectedCompletionPrefixes: [String] = []
    ) -> CotypingBenchmarkScenario {
        CotypingBenchmarkScenario(
            id: "wc-test", name: "Complete: follo→w",
            field: CotypingField(
                appName: "Notes", bundleID: "com.apple.Notes", processID: 1, role: "AXTextArea",
                precedingText: "I wanted to follo", trailingText: "", selectionLength: 0,
                caretRect: .zero, isSecure: false, caretIsExact: true),
            expectedTerms: [],
            latencyTargetMs: 2000,
            allowedSuppressions: allowedSuppressions,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: expectedCompletionPrefixes,
            wordPrefixIsValidWord: false)
    }

    @MainActor
    private func evaluate(
        _ scenario: CotypingBenchmarkScenario,
        text: String,
        suppression: CotypingSuppressionReason? = nil
    ) -> CotypingBenchmarkCaseResult {
        CotypingBenchmarkRunner.evaluate(
            scenario: scenario, text: text, suppression: suppression, latencyMs: 100)
    }

    @MainActor
    func testFragmentExtendingTextPassesAndCountsAsWordCompletionHit() {
        let result = evaluate(scenario(), text: "w up")
        XCTAssertTrue(result.passedSafety)
        XCTAssertTrue(result.wordCompletionHit)
    }

    @MainActor
    func testWhitespaceLeadingTextFailsWordCompletion() {
        // " up" after "follo" would insert "follo up" — the exact bug class the
        // criterion exists to catch.
        let result = evaluate(scenario(), text: " up")
        XCTAssertFalse(result.passedSafety)
        XCTAssertFalse(result.wordCompletionHit)
    }

    @MainActor
    func testEmptyTextPassesOnlyWhenSuppressionIsExplicitlyAllowed() {
        let allowed = evaluate(
            scenario(allowedSuppressions: [.wordCompletionMismatch]),
            text: "", suppression: .wordCompletionMismatch)
        XCTAssertTrue(allowed.passedSafety)
        XCTAssertFalse(allowed.wordCompletionHit)

        let refused = evaluate(scenario(), text: "", suppression: .wordCompletionMismatch)
        XCTAssertFalse(refused.passedSafety)
    }

    @MainActor
    func testExpectedCompletionPrefixesConstrainTheTail() {
        XCTAssertTrue(evaluate(scenario(expectedCompletionPrefixes: ["w"]), text: "w up").passedSafety)
        XCTAssertFalse(evaluate(scenario(expectedCompletionPrefixes: ["w"]), text: "xup").passedSafety)
    }

    @MainActor
    func testPromptScaffoldingAlwaysFailsSafety() {
        XCTAssertFalse(evaluate(
            scenario(),
            text: "On the clipboard: secret release plan").passedSafety)
        XCTAssertFalse(evaluate(
            scenario(),
            text: "Previously accepted completion: send it tomorrow").passedSafety)
    }

    @MainActor
    func testJSONReportCarriesWordCompletionCounters() throws {
        // side_by_side.py parses these keys; renaming or dropping them breaks
        // the scriptable A/B evaluation.
        let summary = CotypingBenchmarkSummary(results: [
            evaluate(scenario(), text: "w up"),
            evaluate(scenario(), text: " up"),
        ])
        let object = try JSONSerialization.jsonObject(with: Data(summary.jsonReport().utf8))
        let report = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(report["wordCompletionPassed"] as? Int, 1)
        XCTAssertEqual(report["wordCompletionTotal"] as? Int, 2)
        let scenarios = try XCTUnwrap(report["scenarios"] as? [[String: Any]])
        XCTAssertEqual(scenarios.count, 2)
    }

    func testDefaultScenariosKeepCotypistParityIds() {
        // External tooling filters on these ids; the parity suite must retain a
        // word-completion scenario and the mid-word safety scenario.
        let ids = Set(CotypingBenchmarkScenario.defaults.map(\.id))
        XCTAssertTrue(ids.contains("wc-follow"))
        XCTAssertTrue(ids.contains("mid-word"))
        XCTAssertTrue(CotypingBenchmarkScenario.defaults.contains(where: \.expectsWordCompletion))
    }
}
