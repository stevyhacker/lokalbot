import XCTest
@testable import LokalBotV1

/// Behavioral tests for the pure logic added with the Cotabby-derived subsystems.
/// Everything here is deterministic and runs off the main actor.
final class ReuseSubsystemsTests: XCTestCase {

    // MARK: - SettingsSearchRanker

    func testSearchEmptyQueryMatchesEverything() {
        XCTAssertTrue(SettingsSearchRanker.matches(query: "", haystack: ["Updates", "sparkle"]))
        XCTAssertTrue(SettingsSearchRanker.matches(query: "   ", haystack: []))
    }

    func testSearchMatchesIsCaseInsensitiveSubstring() {
        XCTAssertTrue(SettingsSearchRanker.matches(query: "UPDATE", haystack: ["Updates", "version"]))
        XCTAssertTrue(SettingsSearchRanker.matches(query: "spark", haystack: ["updates", "sparkle"]))
    }

    func testSearchRequiresAllTokensPresent() {
        // Both tokens appear (across different haystack entries) → match.
        XCTAssertTrue(SettingsSearchRanker.matches(query: "auto update",
                                                   haystack: ["Updates", "automatic check"]))
        // One token missing → no match.
        XCTAssertFalse(SettingsSearchRanker.matches(query: "auto banana",
                                                    haystack: ["Updates", "automatic check"]))
    }

    // MARK: - ModelFit

    private func capability(gb: UInt64, appleSilicon: Bool = true) -> HardwareCapability {
        HardwareCapability(physicalMemoryBytes: gb * 1_073_741_824, isAppleSilicon: appleSilicon)
    }

    func testModelFitComfortableForSmallModelOnLargeRAM() {
        XCTAssertEqual(ModelFit.evaluate(modelSizeGB: 1.0, capability: capability(gb: 16)), .comfortable)
    }

    func testModelFitTightInMidBand() {
        // 8 GB → comfortable ≤4.8, too-large >6.4. 4 GB model needs ~5.2 → tight.
        XCTAssertEqual(ModelFit.evaluate(modelSizeGB: 4.0, capability: capability(gb: 8)), .tight)
    }

    func testModelFitTooLargeBeyondHeadroom() {
        // 8 GB, 6 GB model needs ~7.8 > 6.4 → too large.
        XCTAssertEqual(ModelFit.evaluate(modelSizeGB: 6.0, capability: capability(gb: 8)), .tooLarge)
        XCTAssertNotNil(ModelFit.tooLarge.advisory)
    }

    // MARK: - DownloadOutcomeClassifier

    func testClassifySuccessRequiresGGUFAndOKStatus() {
        XCTAssertEqual(DownloadOutcomeClassifier.classify(httpStatus: 200, error: nil, looksLikeGGUF: true), .success)
    }

    func testClassifyNon2xxIsHTTPError() {
        XCTAssertEqual(DownloadOutcomeClassifier.classify(httpStatus: 404, error: nil, looksLikeGGUF: false),
                       .httpError(404))
    }

    func testClassifyOKButNotGGUF() {
        XCTAssertEqual(DownloadOutcomeClassifier.classify(httpStatus: 200, error: nil, looksLikeGGUF: false),
                       .notGGUF)
    }

    func testClassifyCancellationWinsOverEverything() {
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertEqual(DownloadOutcomeClassifier.classify(httpStatus: 500, error: cancelled, looksLikeGGUF: false),
                       .cancelled)
    }

    func testClassifyTransportError() {
        let dns = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        guard case .transport = DownloadOutcomeClassifier.classify(httpStatus: nil, error: dns, looksLikeGGUF: false) else {
            return XCTFail("expected transport outcome")
        }
    }

    // MARK: - TokenCountEstimator / WordCountFormatter

    func testTokenEstimateZeroForEmptyAndMonotonic() {
        XCTAssertEqual(TokenCountEstimator.estimate(""), 0)
        let short = TokenCountEstimator.estimate("hello world")
        let long = TokenCountEstimator.estimate(String(repeating: "hello world ", count: 50))
        XCTAssertGreaterThan(short, 0)
        XCTAssertGreaterThan(long, short)
    }

    func testWordCountFormatterSingularAndGrouping() {
        XCTAssertEqual(WordCountFormatter.format(words: 1), "1 word")
        XCTAssertEqual(WordCountFormatter.format(words: 2), "2 words")
        XCTAssertEqual(WordCountFormatter.format(words: 1234), "1,234 words")
    }

    // MARK: - PromptContextSanitizer

    func testSanitizerCollapsesBlankLinesAndStripsControlChars() {
        let dirty = "a\u{0007}b\n\n\n\nc"
        let clean = PromptContextSanitizer.sanitize(dirty)
        XCTAssertFalse(clean.contains("\u{0007}"))
        XCTAssertFalse(clean.contains("\n\n\n"))   // at most one blank line between paragraphs
    }

    func testSanitizerHonoursMaxCharacters() {
        let capped = PromptContextSanitizer.sanitize(String(repeating: "word ", count: 100), maxCharacters: 20)
        XCTAssertLessThanOrEqual(capped.count, 20)
    }

    // MARK: - PromptSectionBudget

    func testBudgetLeavesEverythingWhenItFits() {
        let result = PromptSectionBudget().fit(
            sections: [.init(label: "a", text: "aaaa", priority: 1, minCharacters: 1),
                       .init(label: "b", text: "bbbb", priority: 2, minCharacters: 1)],
            totalBudget: 100)
        XCTAssertEqual(result.first { $0.label == "a" }?.text, "aaaa")
        XCTAssertEqual(result.first { $0.label == "b" }?.text, "bbbb")
    }

    func testBudgetTrimsLowestPriorityFirstWithinBudget() {
        let result = PromptSectionBudget().fit(
            sections: [.init(label: "low", text: "aaaa", priority: 1, minCharacters: 1),
                       .init(label: "high", text: "bbbb", priority: 2, minCharacters: 1)],
            totalBudget: 4)
        let total = result.reduce(0) { $0 + $1.text.count }
        XCTAssertLessThanOrEqual(total, 4)
        let low = result.first { $0.label == "low" }?.text.count ?? 0
        let high = result.first { $0.label == "high" }?.text.count ?? 0
        XCTAssertGreaterThanOrEqual(high, low)   // higher priority keeps at least as much
    }

    // MARK: - AppleIntelligenceEngine prompt composition (pure helpers)

    func testComposePromptJoinsContextAndDropsBlanks() {
        let composed = AppleIntelligenceEngine.composePrompt(prompt: "TASK", context: ["A", "", "B"])
        XCTAssertTrue(composed.contains("A"))
        XCTAssertTrue(composed.contains("B"))
        XCTAssertTrue(composed.hasSuffix("TASK"))   // task instruction must survive at the tail
        XCTAssertFalse(composed.contains("\n\n\n"))
    }

    func testCappedToTailKeepsTrailingCharacters() {
        XCTAssertEqual(AppleIntelligenceEngine.cappedToTail("abcdef", limit: 3), "def")
        XCTAssertEqual(AppleIntelligenceEngine.cappedToTail("ab", limit: 5), "ab")
    }
}
