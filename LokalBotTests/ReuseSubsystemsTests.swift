import XCTest
@testable import LokalBot

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

    func testSearchNormalizesPunctuationAndDiacritics() {
        XCTAssertTrue(SettingsSearchRanker.matches(query: "menu-bar",
                                                   haystack: ["General", "menu bar", "dock icon"]))
        XCTAssertTrue(SettingsSearchRanker.matches(query: "floating/pill",
                                                   haystack: ["Dictation", "floating pill", "overlay"]))
        XCTAssertTrue(SettingsSearchRanker.matches(query: "resume",
                                                   haystack: ["Résumé language"]))
    }

    func testSearchFindsMicTermsInDictationHaystack() {
        XCTAssertTrue(SettingsSearchRanker.matches(query: "selected mic",
                                                   haystack: ["Dictation", "selected mic", "input device"]))
    }

    func testSearchFindsLiveDictationTerms() {
        XCTAssertTrue(SettingsSearchRanker.matches(query: "live transcript",
                                                   haystack: ["Dictation", "live", "transcript", "streaming"]))
    }

    // MARK: - DictationLiveTranscript

    func testDictationLiveTranscriptKeepsTrailingWordsTentative() {
        let preview = DictationLiveTranscript.preview(
            from: "We should ship the release notes before the next design review")

        XCTAssertEqual(preview.committed, "We should ship the release")
        XCTAssertEqual(preview.tentative, "notes before the next design review")
        XCTAssertEqual(preview.displayText, "We should ship the release notes before the next design review")
    }

    func testDictationLiveTranscriptCommitsCompletedSentences() {
        let preview = DictationLiveTranscript.preview(
            from: "We shipped the fix. Next we should verify the install")

        XCTAssertEqual(preview.committed, "We shipped the fix.")
        XCTAssertEqual(preview.tentative, "Next we should verify the install")
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

    func testParallelRangeDownloaderSplitsContiguousRanges() {
        let ranges = ParallelRangeDownloader.ranges(totalBytes: 10, partSize: 4)
        XCTAssertEqual(ranges, [
            .init(index: 0, start: 0, end: 3),
            .init(index: 1, start: 4, end: 7),
            .init(index: 2, start: 8, end: 9),
        ])
        XCTAssertEqual(ranges.map(\.length), [4, 4, 2])
    }

    func testParallelRangeDownloaderRejectsInvalidRangeInputs() {
        XCTAssertTrue(ParallelRangeDownloader.ranges(totalBytes: 0, partSize: 4).isEmpty)
        XCTAssertTrue(ParallelRangeDownloader.ranges(totalBytes: 10, partSize: 0).isEmpty)
    }

    /// Two attempts at the same URL must land on the same stash so a retry
    /// resumes; different URLs must never share one.
    func testParallelRangeDownloaderStashNameIsStablePerURL() throws {
        let a = try XCTUnwrap(URL(string: "https://example.com/model.gguf"))
        let b = try XCTUnwrap(URL(string: "https://example.com/other.gguf"))
        XCTAssertEqual(ParallelRangeDownloader.stashName(for: a),
                       ParallelRangeDownloader.stashName(for: a))
        XCTAssertNotEqual(ParallelRangeDownloader.stashName(for: a),
                          ParallelRangeDownloader.stashName(for: b))
    }

    /// The disk-space precheck credits stashed bytes against the expected
    /// download size, so the count must read the actual partial for that URL
    /// (by allocated size) and be 0 — never an error — when nothing is stashed.
    func testParallelRangeDownloaderCountsStashedBytesForItsURLOnly() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/model.gguf"))
        let other = try XCTUnwrap(URL(string: "https://example.com/other.gguf"))
        let stashDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-stash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stashDir) }

        XCTAssertEqual(ParallelRangeDownloader.stashedByteCount(
            for: url, stashDirectory: stashDir), 0, "missing stash directory must count as 0")

        try FileManager.default.createDirectory(at: stashDir, withIntermediateDirectories: true)
        try Data(count: 64_000).write(
            to: ParallelRangeDownloader.stashPartialURL(for: url, in: stashDir))

        let counted = ParallelRangeDownloader.stashedByteCount(for: url, stashDirectory: stashDir)
        XCTAssertGreaterThanOrEqual(counted, 64_000,
                                    "the partial's disk bytes must be credited")
        XCTAssertEqual(ParallelRangeDownloader.stashedByteCount(
            for: other, stashDirectory: stashDir), 0,
            "another URL's stash must never be credited")
    }

    func testParallelRangeDownloaderResumeStateRoundTrips() throws {
        let state = ParallelRangeDownloader.ResumeState(
            url: "https://example.com/model.gguf", totalBytes: 1_000,
            partSize: 100, completedParts: [0, 3, 7])

        let decoded = try JSONDecoder().decode(
            ParallelRangeDownloader.ResumeState.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(decoded, state)
    }

    // MARK: - DiskSpacePrecheck

    func testDiskSpacePrecheckPassesWithRoom() {
        XCTAssertNil(DiskSpacePrecheck.advisory(
            expectedBytes: 1_000_000_000,
            availableBytes: 1_000_000_000 + DiskSpacePrecheck.headroomBytes))
    }

    func testDiskSpacePrecheckRefusesWhenModelPlusHeadroomWontFit() {
        let message = DiskSpacePrecheck.advisory(
            expectedBytes: 17_730_000_000, availableBytes: 18_000_000_000)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("free disk space") == true)
    }

    /// Unknown size or unreadable volume must not block a download — the
    /// precheck is an early courtesy, not a gate that can wedge shut.
    func testDiskSpacePrecheckSkipsWhenSizesUnknown() {
        XCTAssertNil(DiskSpacePrecheck.advisory(expectedBytes: nil, availableBytes: 1))
        XCTAssertNil(DiskSpacePrecheck.advisory(expectedBytes: 0, availableBytes: 1))
        XCTAssertNil(DiskSpacePrecheck.advisory(expectedBytes: 1_000, availableBytes: nil))
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

    // MARK: - ProcessingPipeline.digestContext (screenshot OCR → day digest)

    func testDigestContextIncludesScreenOCRWhenPresent() {
        let ctx = ProcessingPipeline.digestContext(
            date: Date(), ocr: "[Xcode] func generateDayDigest() — launch failed")
        // Date block is always first; non-empty OCR adds a second screen-text block.
        XCTAssertEqual(ctx.count, 2)
        let screen = ctx[1]
        XCTAssertTrue(screen.hasPrefix("Screen text"))
        // The actual on-screen content reaches the prompt — not just window titles.
        XCTAssertTrue(screen.contains("generateDayDigest"))
        XCTAssertTrue(screen.contains("launch failed"))
    }

    func testDigestContextOmitsScreenBlockWhenOCRBlank() {
        XCTAssertEqual(ProcessingPipeline.digestContext(date: Date(), ocr: "").count, 1)
        // Whitespace-only OCR sanitizes to empty, so no dangling screen block.
        XCTAssertEqual(ProcessingPipeline.digestContext(date: Date(), ocr: "  \n\t  ").count, 1)
    }

    func testDigestContextCapsLargeOCR() {
        let ctx = ProcessingPipeline.digestContext(
            date: Date(), ocr: String(repeating: "x", count: 50_000))
        XCTAssertEqual(ctx.count, 2)
        // A busy day's screen text is capped so it can't blow the prompt budget.
        XCTAssertLessThan(ctx[1].count, 13_000)
    }
}
