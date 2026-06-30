import AppKit
import XCTest
@testable import LokalBot

// MARK: - Prompt renderer

final class CotypingPromptRendererTests: XCTestCase {
    func testBarePrefixWhenNoPreface() {
        XCTAssertEqual(CotypingPromptRenderer.prompt(prefixText: "Hello wo"), "Hello wo")
    }

    func testTrailingWhitespaceTrimmed() {
        XCTAssertEqual(CotypingPromptRenderer.prompt(prefixText: "Hello wo  \n\t"), "Hello wo")
    }

    func testPersonaPreface() {
        XCTAssertEqual(
            CotypingPromptRenderer.prompt(prefixText: "x", userName: "Jacob"),
            "Written by Jacob.\n\nx")
    }

    func testFullPrefaceOrder() {
        let prompt = CotypingPromptRenderer.prompt(
            prefixText: "the caret text",
            userName: "Ada", styleNote: "concise", languageHint: "Writes in German.")
        XCTAssertEqual(prompt, "Written by Ada.\nWriting style: concise.\nWrites in German.\n\nthe caret text")
    }

    func testBlankPersonaIgnored() {
        XCTAssertEqual(CotypingPromptRenderer.prompt(prefixText: "x", userName: "   "), "x")
    }

    func testLearnedExamplesEnterPrefaceBeforePrefix() {
        let prompt = CotypingPromptRenderer.prompt(
            prefixText: "Thanks for",
            learnedExamples: ["following up with the final numbers"])
        XCTAssertEqual(
            prompt,
            "Previously accepted completion: following up with the final numbers\n\nThanks for")
    }

    func testRendererHonorsAllProvidedLearnedExamples() {
        let examples = (1...5).map { "example \($0)" }
        let prompt = CotypingPromptRenderer.prompt(prefixText: "Thanks", learnedExamples: examples)
        for example in examples {
            XCTAssertTrue(prompt.contains("Previously accepted completion: \(example)"))
        }
    }
}

// MARK: - Local learning

final class CotypingLearningRankerTests: XCTestCase {
    private func field(
        preceding: String,
        appName: String = "Mail",
        bundleID: String? = "com.apple.mail",
        windowTitle: String? = nil
    ) -> CotypingField {
        CotypingField(
            appName: appName, bundleID: bundleID, processID: 1, role: "AXTextArea",
            precedingText: preceding, trailingText: "", selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true,
            windowTitle: windowTitle)
    }

    func testSanitizesAcceptedText() {
        XCTAssertEqual(
            CotypingLearningRanker.acceptedText("  thanks\u{0000}\nagain  "),
            "thanks again")
        XCTAssertNil(CotypingLearningRanker.acceptedText("ok"))
    }

    func testDoesNotLearnInSecureFieldsOrTerminals() {
        var secure = field(preceding: "password")
        secure.isSecure = true
        XCTAssertFalse(CotypingLearningRanker.canLearn(from: secure))
        XCTAssertFalse(CotypingLearningRanker.canLearn(from: field(
            preceding: "ls",
            appName: "Terminal",
            bundleID: "com.apple.Terminal")))
    }

    func testRankingPrefersSameBundleAndPrefixOverlap() {
        let now = Date()
        let examples = [
            CotypingLearningExample(
                id: UUID(), createdAt: now.addingTimeInterval(-30),
                appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                surfaceClass: "chat", contextHint: nil,
                prefixTail: "quick follow up from yesterday",
                acceptedText: "sounds good to me"),
            CotypingLearningExample(
                id: UUID(), createdAt: now.addingTimeInterval(-60),
                appName: "Mail", bundleID: "com.apple.mail",
                surfaceClass: "email", contextHint: nil,
                prefixTail: "quick follow up on the contract",
                acceptedText: "I can send the final version today"),
        ]

        let ranked = CotypingLearningRanker.rankedExamples(
            examples,
            for: field(preceding: "quick follow up"),
            limit: 1)

        XCTAssertEqual(ranked, ["I can send the final version today"])
    }

    func testRankingDropsWeaklyRelatedExamples() {
        let examples = [
            CotypingLearningExample(
                id: UUID(), createdAt: Date(),
                appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                surfaceClass: "chat", contextHint: nil,
                prefixTail: "unrelated thread about dinner",
                acceptedText: "sounds good to me"),
        ]

        let ranked = CotypingLearningRanker.rankedExamples(
            examples,
            for: field(preceding: "quick follow up"),
            limit: 1)

        XCTAssertEqual(ranked, [])
    }

    func testRankingUsesContextAndDeduplicates() {
        let now = Date()
        let examples = [
            CotypingLearningExample(
                id: UUID(), createdAt: now.addingTimeInterval(-10),
                appName: "Mail", bundleID: "com.apple.mail",
                surfaceClass: "email", contextHint: nil,
                prefixTail: "quick follow up",
                acceptedText: "I can send the final version today"),
            CotypingLearningExample(
                id: UUID(), createdAt: now.addingTimeInterval(-20),
                appName: "Mail", bundleID: "com.apple.mail",
                surfaceClass: "email",
                contextHint: "An email being written in Mail. The window is titled \"Q3 planning\".",
                prefixTail: "quick follow up",
                acceptedText: "I can send the final version today"),
            CotypingLearningExample(
                id: UUID(), createdAt: now.addingTimeInterval(-30),
                appName: "Mail", bundleID: "com.apple.mail",
                surfaceClass: "email",
                contextHint: "An email being written in Mail. The window is titled \"Q3 planning\".",
                prefixTail: "quick follow up",
                acceptedText: "I will follow up on the Q3 planning notes"),
        ]

        let ranked = CotypingLearningRanker.rankedExamples(
            examples,
            for: field(preceding: "quick follow up", windowTitle: "Q3 planning"),
            limit: 3)

        XCTAssertEqual(ranked.first, "I can send the final version today")
        XCTAssertEqual(ranked.count, 2)
    }
}

// MARK: - Recommended cotyping model preparation

final class CotypingModelPreparationTests: XCTestCase {
    func testStatusPrefersDownloadProgressOverMissing() throws {
        let entry = ModelCatalog.entry(id: ModelCatalog.recommendedCotypingID)
        let status = CotypingModelPreparer.status(
            for: entry,
            localURL: nil,
            progress: 0.42,
            error: nil)

        XCTAssertEqual(status, .downloading(try XCTUnwrap(entry), 0.42))
        XCTAssertTrue(status.isDownloading)
    }

    func testReadyWhenLocalURLExists() throws {
        let entry = try XCTUnwrap(ModelCatalog.entry(id: ModelCatalog.recommendedCotypingID))
        let status = CotypingModelPreparer.status(
            for: entry,
            localURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            progress: nil,
            error: nil)

        XCTAssertEqual(status, .ready(entry))
    }

    func testRecommendedActiveTracksModelID() {
        var settings = AppSettings()
        // Cotyping always runs its own model; the recommended Gemma id is the default.
        XCTAssertTrue(CotypingModelPreparer.recommendedIsActive(settings: settings))
        settings.cotypingBuiltInModelID = ModelCatalog.bundledID
        XCTAssertFalse(CotypingModelPreparer.recommendedIsActive(settings: settings))
    }

    func testPrepareActionDownloadsBeforeActivatingMissingModel() {
        XCTAssertEqual(CotypingModelPreparer.action(localURL: nil, isDownloading: false), .download)
        XCTAssertEqual(CotypingModelPreparer.action(localURL: nil, isDownloading: true), .wait)
        XCTAssertEqual(
            CotypingModelPreparer.action(localURL: URL(fileURLWithPath: "/tmp/model.gguf"), isDownloading: false),
            .activate)
    }
}

// MARK: - Quality benchmark

@MainActor
private final class StaticCotypingEngine: CotypingCompleting {
    var output: String
    var partial: String?

    init(output: String, partial: String? = nil) {
        self.output = output
        self.partial = partial
    }

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        CotypingNormalizationResult(text: output, suppression: nil)
    }

    func generateStreaming(_ request: CotypingRequest,
                           onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void) async throws -> CotypingNormalizationResult {
        if let partial {
            onPartial(CotypingNormalizationResult(text: partial, suppression: nil))
        }
        return CotypingNormalizationResult(text: output, suppression: nil)
    }
}

final class CotypingBenchmarkTests: XCTestCase {
    @MainActor
    func testEvaluatorTracksSafetyLatencyAndKeywordHints() {
        let scenario = CotypingBenchmarkScenario.defaults[0]
        let result = CotypingBenchmarkRunner.evaluate(
            scenario: scenario,
            text: " up with the final numbers today",
            suppression: nil,
            latencyMs: 220,
            firstVisibleLatencyMs: 120)

        XCTAssertTrue(result.passedSafety)
        XCTAssertTrue(result.metLatencyTarget)
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.latencyForTargetMs, 120)
        XCTAssertGreaterThan(result.expectedTermHits, 0)
    }

    @MainActor
    func testEvaluatorAllowsExpectedSuppressionForSafetyScenario() {
        let scenario = CotypingBenchmarkScenario.defaults.first { $0.id == "mid-word" }!
        let result = CotypingBenchmarkRunner.evaluate(
            scenario: scenario,
            text: "",
            suppression: .unsafeToInsert,
            latencyMs: 90)

        XCTAssertTrue(result.passedSafety)
        XCTAssertTrue(result.metLatencyTarget)
        XCTAssertTrue(result.passed)
        XCTAssertFalse(result.expectedVisibleSuggestion)
        XCTAssertTrue(result.allowedSuppression)
    }

    @MainActor
    func testRunnerMatchesCotypistDefaultByNotRecordingPartialLatency() async {
        let summary = await CotypingBenchmarkRunner.run(
            scenarios: Array(CotypingBenchmarkScenario.defaults.prefix(3)),
            engine: StaticCotypingEngine(output: " up today", partial: " up"),
            config: .standard,
            personalization: .none)

        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.safetyPassed, summary.total)
        XCTAssertNotNil(summary.averageLatencyMs)
        XCTAssertNil(summary.averageFirstVisibleLatencyMs)
        XCTAssertNotNil(summary.p95LatencyMs)
        XCTAssertNil(summary.p95FirstVisibleLatencyMs)
    }

    @MainActor
    func testRunnerRecordsFirstVisibleLatencyWhenStreamingEnabled() async {
        let summary = await CotypingBenchmarkRunner.run(
            scenarios: Array(CotypingBenchmarkScenario.defaults.prefix(3)),
            engine: StaticCotypingEngine(output: " up today", partial: " up"),
            config: .standard,
            personalization: .none,
            streamPartials: true)

        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.safetyPassed, summary.total)
        XCTAssertNotNil(summary.averageLatencyMs)
        XCTAssertNotNil(summary.averageFirstVisibleLatencyMs)
        XCTAssertNotNil(summary.p95LatencyMs)
        XCTAssertNotNil(summary.p95FirstVisibleLatencyMs)
    }
}

// MARK: - Decode stop policy

final class CotypingDecodeStopPolicyTests: XCTestCase {
    func testStopsAfterSentenceBoundaryOnceEnoughChunksArrive() {
        XCTAssertEqual(
            CotypingDecodeStopPolicy.verdict(
                accumulated: " up with the final numbers today.",
                tokensGenerated: 4),
            .sentenceBoundary)
    }

    func testDoesNotStopOnCommonAbbreviation() {
        XCTAssertNil(CotypingDecodeStopPolicy.verdict(
            accumulated: " to review e.g.",
            tokensGenerated: 4))
    }

    func testDoesNotStopOnDecimal() {
        XCTAssertNil(CotypingDecodeStopPolicy.verdict(
            accumulated: " by version 1.2",
            tokensGenerated: 4))
    }

    func testStopsOnScaffoldingMarkerWithoutMinimumTokenDelay() {
        XCTAssertEqual(
            CotypingDecodeStopPolicy.verdict(
                accumulated: "<end_of_turn>",
                tokensGenerated: 1),
            .scaffoldingMarker)
    }
}

// MARK: - Text normalizer

final class CotypingTextNormalizerTests: XCTestCase {
    private func request(
        prefix: String,
        trailing: String = "",
        multiLine: Bool = false,
        maxWords: Int = 6
    ) -> CotypingRequest {
        CotypingRequest(
            prompt: CotypingPromptRenderer.prompt(prefixText: prefix),
            prefixText: prefix, trailingText: trailing, isMultiLine: multiLine,
            maxTokens: 24, maxWords: maxWords, temperature: 0.1, topP: 0.7, topK: 20, minP: 0.08,
            repeatPenalty: 1.05, seed: 0, generation: 0)
    }

    func testSingleLineCollapse() {
        let result = CotypingTextNormalizer.normalize("brown fox\nand more", for: request(prefix: "The quick "))
        XCTAssertEqual(result, "brown fox")
    }

    func testStripsPromptEcho() {
        let result = CotypingTextNormalizer.normalize("The quick brown fox", for: request(prefix: "The quick "))
        XCTAssertEqual(result, "brown fox")
    }

    func testTruncatesAtControlToken() {
        let result = CotypingTextNormalizer.normalize("brown<|im_end|> trailing junk", for: request(prefix: "The quick "))
        XCTAssertEqual(result, "brown")
    }

    func testStripsThinkBlock() {
        let result = CotypingTextNormalizer.normalize("<think>reasoning here</think>delicious", for: request(prefix: "It tastes "))
        XCTAssertEqual(result, "delicious")
    }

    func testSuppressesTrailingDuplication() {
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            "tomorrow", for: request(prefix: "See you ", trailing: "tomorrow at noon"))
        XCTAssertEqual(detailed.text, "")
        XCTAssertEqual(detailed.suppression, .duplicatesTrailingText)
    }

    func testStripsEchoedPrecedingWords() {
        let result = CotypingTextNormalizer.normalize("like to eat", for: request(prefix: "i like "))
        XCTAssertEqual(result, "to eat")
    }

    func testStripsLeadingScaffoldingLabel() {
        let result = CotypingTextNormalizer.normalize("Continuation: hello there", for: request(prefix: "x "))
        XCTAssertEqual(result, "hello there")
    }

    func testStripsBenignInlineMarkupInsteadOfSuppressingSuggestion() {
        let result = CotypingTextNormalizer.normalize(
            "that you can't use the same <code>.env</code> file for both development and production",
            for: request(prefix: "The main tradeoff is "))
        XCTAssertEqual(result, "that you can't use the same")
    }

    func testRejectsWhitespaceOnly() {
        let detailed = CotypingTextNormalizer.normalizeDetailed("   \n  ", for: request(prefix: "Hello "))
        XCTAssertEqual(detailed.text, "")
        XCTAssertEqual(detailed.suppression, .emptyGeneration)
    }

    func testKeepsMultipleLinesInMultiLineMode() {
        let result = CotypingTextNormalizer.normalize(
            "line one\nline two\n\nignored", for: request(prefix: "Start ", multiLine: true))
        XCTAssertEqual(result, "line one\nline two")
    }

    func testSuppressesBracketPlaceholderSuggestions() {
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            "up on [the project/your email]",
            for: request(prefix: "I wanted to follow "))
        XCTAssertEqual(detailed.text, "")
        XCTAssertEqual(detailed.suppression, .placeholderText)
    }

    func testSuppressesUnicodePlaceholderSuggestions() {
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            "up on [пројекат]",
            for: request(prefix: "I wanted to follow "))
        XCTAssertEqual(detailed.text, "")
        XCTAssertEqual(detailed.suppression, .placeholderText)
    }

    func testTruncatesBeforeSecondSentenceQuestion() {
        let result = CotypingTextNormalizer.normalize(
            "care of that. What would you like me to do next?",
            for: request(prefix: "I can take "))
        XCTAssertEqual(result, "care of that.")
    }

    func testSuppressesNewQuestionContinuation() {
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            "What would you like me to do next?",
            for: request(prefix: "I can take "))
        XCTAssertEqual(detailed.text, "")
        XCTAssertEqual(detailed.suppression, .questionContinuation)
    }

    func testAllowsHowToContinuationWithoutQuestionMark() {
        let result = CotypingTextNormalizer.normalize(
            "how to fix it",
            for: request(prefix: "I'll show you "))
        XCTAssertEqual(result, "how to fix it")
    }

    func testCapsSingleLineSuggestionsToShortPhrase() {
        let result = CotypingTextNormalizer.normalize(
            "one two three four five six seven eight",
            for: request(prefix: "Let's "))
        XCTAssertEqual(result, "one two three four five six")
    }

    func testSingleLineWordCapUsesRequestMaxWords() {
        let result = CotypingTextNormalizer.normalize(
            "one two three four five six seven eight",
            for: request(prefix: "Let's ", maxWords: 8))
        XCTAssertEqual(result, "one two three four five six seven eight")
    }
}

// MARK: - Trailing duplication filter

final class CotypingTrailingDuplicationFilterTests: XCTestCase {
    func testCompletionIsPrefixOfTrailing() {
        XCTAssertTrue(CotypingTrailingDuplicationFilter.duplicatesTrailingText("tomor", trailingText: "tomorrow"))
    }

    func testShortOverlapNotSuppressed() {
        XCTAssertFalse(CotypingTrailingDuplicationFilter.duplicatesTrailingText("a", trailingText: "apple"))
    }

    func testIgnoresLeadingPunctuationWhenFolding() {
        XCTAssertTrue(CotypingTrailingDuplicationFilter.duplicatesTrailingText("- world", trailingText: "world peace"))
    }

    func testUnrelatedTextNotSuppressed() {
        XCTAssertFalse(CotypingTrailingDuplicationFilter.duplicatesTrailingText("brand new idea", trailingText: "old plan"))
    }
}

// MARK: - Marker selection synthesis

final class CotypingMarkerSelectionSynthesizerTests: XCTestCase {
    func testCaretInMiddleProducesZeroLengthSelectionAtBeforeLength() {
        let result = CotypingMarkerSelectionSynthesizer.make(
            beforeCaret: "Hello ",
            selected: "",
            afterCaret: "world")

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.selection, NSRange(location: 6, length: 0))
    }

    func testNonEmptySelectionIndexesIntoSynthesizedText() {
        let result = CotypingMarkerSelectionSynthesizer.make(
            beforeCaret: "Hi ",
            selected: "there",
            afterCaret: "!")

        XCTAssertEqual(result.text, "Hi there!")
        XCTAssertEqual(result.selection, NSRange(location: 3, length: 5))
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "there")
    }

    func testWindowingKeepsCaretAdjacentTextAndSelectionConsistent() {
        let result = CotypingMarkerSelectionSynthesizer.make(
            beforeCaret: "ABCDEFG",
            selected: "X",
            afterCaret: "HIJKLM",
            window: 3)

        XCTAssertEqual(result.text, "EFGXHIJ")
        XCTAssertEqual(result.selection, NSRange(location: 3, length: 1))
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "X")
    }

    func testWindowDoesNotSplitSurrogatePairs() {
        let result = CotypingMarkerSelectionSynthesizer.make(
            beforeCaret: "😀😀😀",
            selected: "",
            afterCaret: "",
            window: 3)

        XCTAssertFalse(result.text.unicodeScalars.contains("\u{FFFD}"))
        XCTAssertTrue(result.text.allSatisfy { $0 == "😀" })
        XCTAssertEqual(result.selection.location, (result.text as NSString).length)
        XCTAssertEqual(result.selection.length, 0)
    }

    func testShorterThanWindowIsUnchanged() {
        let result = CotypingMarkerSelectionSynthesizer.make(
            beforeCaret: "ab",
            selected: "",
            afterCaret: "cd",
            window: 100)

        XCTAssertEqual(result.text, "abcd")
        XCTAssertEqual(result.selection, NSRange(location: 2, length: 0))
    }
}

final class CotypingWebAccessibilityPrimingTests: XCTestCase {
    func testChromiumBrowsersNeedPriming() {
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.google.Chrome"))
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.google.Chrome.canary"))
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "company.thebrowser.Browser"))
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.brave.Browser"))
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.microsoft.edgemac"))
    }

    func testSafariAndFirefoxDoNotNeedChromiumPriming() {
        XCTAssertFalse(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.apple.Safari"))
        XCTAssertFalse(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "org.mozilla.firefox"))
    }

    func testNamedElectronEditorsNeedPrimingCaseInsensitively() {
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.microsoft.VSCode"))
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.microsoft.vscodeinsiders"))
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.vscodium"))
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.clickup.desktop-app"))
    }

    func testBroadElectronOrToDesktopAppsAreNotPrimedByPrefix() {
        XCTAssertFalse(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.todesktop.12345"))
        XCTAssertFalse(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.electron.random"))
    }
}

// MARK: - Streamed ghost text policy

final class CotypingStreamedGhostTextPolicyTests: XCTestCase {
    func testFirstNonEmptyPartialCanRender() {
        XCTAssertTrue(CotypingStreamedGhostTextPolicy.isRenderableExtension(
            candidate: " up",
            currentlyRendered: nil))
    }

    func testEmptyPartialCannotRender() {
        XCTAssertFalse(CotypingStreamedGhostTextPolicy.isRenderableExtension(
            candidate: "",
            currentlyRendered: nil))
    }

    func testStrictPrefixExtensionCanRender() {
        XCTAssertTrue(CotypingStreamedGhostTextPolicy.isRenderableExtension(
            candidate: " up today",
            currentlyRendered: " up"))
    }

    func testSameOrShorterPartialCannotReplaceRenderedText() {
        XCTAssertFalse(CotypingStreamedGhostTextPolicy.isRenderableExtension(
            candidate: " up",
            currentlyRendered: " up"))
        XCTAssertFalse(CotypingStreamedGhostTextPolicy.isRenderableExtension(
            candidate: " up",
            currentlyRendered: " up today"))
    }

    func testLongerNonPrefixPartialCannotReplaceRenderedText() {
        XCTAssertFalse(CotypingStreamedGhostTextPolicy.isRenderableExtension(
            candidate: " tomorrow",
            currentlyRendered: " today"))
    }
}

// MARK: - Suggestion anchor cache

final class CotypingSuggestionAnchorCacheTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func makeCache() -> CotypingSuggestionAnchorCache {
        CotypingSuggestionAnchorCache(now: { self.clock })
    }

    func testFreshAnchorMatchesAtZeroConsumed() {
        var cache = makeCache()
        cache.record(identityKey: "field", precedingText: "Hello", fullText: " world again")
        XCTAssertEqual(cache.remainder(identityKey: "field", precedingText: "Hello"), " world again")
    }

    func testTypeThroughConsumesPrefix() {
        var cache = makeCache()
        cache.record(identityKey: "field", precedingText: "Hello", fullText: " world again")
        XCTAssertEqual(cache.remainder(identityKey: "field", precedingText: "Hello wo"), "rld again")
    }

    func testBackspaceRollbackRestoresEarlierPosition() {
        var cache = makeCache()
        cache.record(identityKey: "field", precedingText: "Hello", fullText: " world again")
        XCTAssertEqual(cache.remainder(identityKey: "field", precedingText: "Hello wo"), "rld again")
        XCTAssertEqual(cache.remainder(identityKey: "field", precedingText: "Hello"), " world again")
    }

    func testFullyConsumedSuggestionNeverReoffersItsTail() {
        var cache = makeCache()
        cache.record(identityKey: "field", precedingText: "Hello", fullText: " world")
        XCTAssertNil(cache.remainder(identityKey: "field", precedingText: "Hello world"))
    }

    func testDivergentTypingDoesNotMatch() {
        var cache = makeCache()
        cache.record(identityKey: "field", precedingText: "Hello", fullText: " world again")
        XCTAssertNil(cache.remainder(identityKey: "field", precedingText: "Hello wa"))
    }

    func testDifferentFieldDoesNotMatch() {
        var cache = makeCache()
        cache.record(identityKey: "first", precedingText: "Hello", fullText: " world")
        XCTAssertNil(cache.remainder(identityKey: "second", precedingText: "Hello"))
    }

    func testDeepestConsumedMatchWins() {
        var cache = makeCache()
        cache.record(identityKey: "field", precedingText: "Hello", fullText: " world again")
        cache.record(identityKey: "field", precedingText: "Hello wo", fullText: "rld forever")
        XCTAssertEqual(cache.remainder(identityKey: "field", precedingText: "Hello wor"), "ld again")
    }

    func testEntriesExpire() {
        var cache = makeCache()
        cache.record(identityKey: "field", precedingText: "Hello", fullText: " world")
        clock = clock.addingTimeInterval(CotypingSuggestionAnchorCache.maxEntryAge + 1)
        XCTAssertNil(cache.remainder(identityKey: "field", precedingText: "Hello"))
    }

    func testCapacityEvictsOldest() {
        var cache = makeCache()
        for index in 0..<(CotypingSuggestionAnchorCache.capacity + 4) {
            cache.record(identityKey: "field", precedingText: "prefix \(index)", fullText: "suffix \(index)")
        }
        XCTAssertNil(cache.remainder(identityKey: "field", precedingText: "prefix 0"))
        XCTAssertEqual(
            cache.remainder(
                identityKey: "field",
                precedingText: "prefix \(CotypingSuggestionAnchorCache.capacity + 3)"),
            "suffix \(CotypingSuggestionAnchorCache.capacity + 3)")
    }

    func testLongPrefixesMatchOnTheBoundedTail() {
        var cache = makeCache()
        let longPrefix = String(repeating: "a", count: 2_000) + " ending here"
        cache.record(identityKey: "field", precedingText: longPrefix, fullText: " and more")
        XCTAssertEqual(cache.remainder(identityKey: "field", precedingText: longPrefix + " and"), " more")
    }

    func testRemoveAllEmptiesTheCache() {
        var cache = makeCache()
        cache.record(identityKey: "field", precedingText: "Hello", fullText: " world")
        cache.removeAll()
        XCTAssertNil(cache.remainder(identityKey: "field", precedingText: "Hello"))
    }
}

// MARK: - Prefix window + gating

final class CotypingPrefixWindowTests: XCTestCase {
    func testShouldGenerateRequiresNonWhitespace() {
        XCTAssertFalse(CotypingPrefixWindow.shouldGenerate(for: "   \n"))
        XCTAssertTrue(CotypingPrefixWindow.shouldGenerate(for: "hi"))
    }

    func testKeepsTrailingWords() {
        let windowed = CotypingPrefixWindow.truncatedPrefix(
            from: "one two three four", maxCharacters: 100, maxWords: 2)
        XCTAssertEqual(windowed, "three four")
    }

    func testCharacterWindowBoundsLongText() {
        let windowed = CotypingPrefixWindow.truncatedPrefix(
            from: String(repeating: "a", count: 50), maxCharacters: 5, maxWords: 10)
        XCTAssertEqual(windowed, "aaaaa")
    }
}

// MARK: - Request builder

final class CotypingRequestBuilderTests: XCTestCase {
    private func field(preceding: String, trailing: String = "") -> CotypingField {
        CotypingField(
            appName: "Notes", bundleID: "com.apple.Notes", processID: 1, role: "AXTextArea",
            precedingText: preceding, trailingText: trailing, selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true)
    }

    func testNilForBlankContext() {
        let request = CotypingRequestBuilder.build(
            field: field(preceding: "   "), config: .standard,
            personalization: .none, generation: 1)
        XCTAssertNil(request)
    }

    func testBuildsRequestWithPrefixAndGeneration() throws {
        var config = CotypingConfiguration.standard
        config.maxResponseWords = 12
        let request = try XCTUnwrap(CotypingRequestBuilder.build(
            field: field(preceding: "Hello there"), config: config,
            personalization: .none, generation: 7))
        XCTAssertEqual(request.prefixText, "Hello there")
        XCTAssertEqual(request.prompt, "Hello there")
        XCTAssertEqual(request.generation, 7)
        XCTAssertEqual(request.maxTokens, CotypingConfiguration.standard.maxResponseTokens)
        XCTAssertEqual(request.maxWords, 12)
        XCTAssertFalse(request.isMultiLine)
    }

    func testPersonalizationEntersPrompt() throws {
        let personalization = CotypingPersonalization(
            userName: "Sam", styleNote: nil, languageHint: nil, isMultiLine: true, appContextEnabled: false)
        let request = try XCTUnwrap(CotypingRequestBuilder.build(
            field: field(preceding: "Dear team"), config: .standard,
            personalization: personalization, generation: 0))
        XCTAssertTrue(request.prompt.hasPrefix("Written by Sam."))
        XCTAssertTrue(request.isMultiLine)
    }
}

// MARK: - Availability gate

final class CotypingAvailabilityTests: XCTestCase {
    private func focus(app: String = "Slack", bundle: String? = "com.tinyspeck.slackmacgap",
                       capability: CotypingCapability = .supported) -> CotypingFocus {
        CotypingFocus(appName: app, bundleID: bundle, capability: capability, field: nil)
    }

    func testDisabledWhenOff() {
        XCTAssertEqual(
            CotypingAvailability.disabledReason(enabled: false, excludedApps: [], selfBundleID: nil, focus: focus()),
            "Cotyping is off.")
    }

    func testExcludedApp() {
        let reason = CotypingAvailability.disabledReason(
            enabled: true, excludedApps: ["Slack"], selfBundleID: nil, focus: focus())
        XCTAssertEqual(reason, "Disabled in Slack.")
    }

    func testOffInsideSelf() {
        let reason = CotypingAvailability.disabledReason(
            enabled: true, excludedApps: [], selfBundleID: "me.dotenv.LokalBot",
            focus: focus(app: "LokalBot", bundle: "me.dotenv.LokalBot"))
        XCTAssertEqual(reason, "Off in LokalBot.")
    }

    func testBlockedCapabilityReason() {
        let reason = CotypingAvailability.disabledReason(
            enabled: true, excludedApps: [], selfBundleID: nil,
            focus: focus(capability: .blocked("Secure field — never read.")))
        XCTAssertEqual(reason, "Secure field — never read.")
    }

    func testSupportedNotExcludedAllows() {
        XCTAssertNil(CotypingAvailability.disabledReason(
            enabled: true, excludedApps: ["Terminal"], selfBundleID: "me.dotenv.LokalBot", focus: focus()))
    }

    func testTerminalAppsAreBlockedByDefault() {
        let reason = CotypingAvailability.disabledReason(
            enabled: true,
            excludedApps: [],
            selfBundleID: nil,
            focus: focus(app: "Terminal", bundle: "com.apple.Terminal"))
        XCTAssertEqual(reason, "Not available in terminal apps.")
    }

    func testIntegratedTerminalsAreBlockedByDefault() {
        var field = CotypingField(
            appName: "Code", bundleID: "com.microsoft.VSCode", processID: 1,
            role: "AXTextField", precedingText: "npm", trailingText: "",
            selectionLength: 0, caretRect: .zero, isSecure: false,
            isIntegratedTerminal: true, caretIsExact: true)
        let reason = CotypingAvailability.disabledReason(
            enabled: true,
            excludedApps: [],
            selfBundleID: nil,
            focus: CotypingFocus(
                appName: "Code",
                bundleID: "com.microsoft.VSCode",
                capability: .supported,
                field: field))
        XCTAssertEqual(reason, "Not available in the integrated terminal.")

        XCTAssertNil(CotypingAvailability.disabledReason(
            enabled: true,
            excludedApps: [],
            suggestInIntegratedTerminals: true,
            selfBundleID: nil,
            focus: CotypingFocus(
                appName: "Code",
                bundleID: "com.microsoft.VSCode",
                capability: .supported,
                field: field)))

        field.isIntegratedTerminal = false
        XCTAssertNil(CotypingAvailability.disabledReason(
            enabled: true,
            excludedApps: [],
            selfBundleID: nil,
            focus: CotypingFocus(
                appName: "Code",
                bundleID: "com.microsoft.VSCode",
                capability: .supported,
                field: field)))
    }
}

// MARK: - Focus poll backoff

final class CotypingFocusPollBackoffTests: XCTestCase {
    private func idledBackoff(captures count: Int) -> CotypingFocusPollBackoff {
        var backoff = CotypingFocusPollBackoff()
        for _ in 0..<count {
            backoff.recordCapture(didChange: false)
        }
        return backoff
    }

    func testRecentActivityStaysAtFullCadence() {
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 0), 1)
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 4), 1)
    }

    func testStrideGrowsAsIdlePersists() {
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 5), 3)
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 11), 3)
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 12), 6)
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 29), 6)
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 30), 10)
    }

    func testStrideIsMonotonicNonDecreasing() {
        var previous = 0
        for count in 0...120 {
            let stride = CotypingFocusPollBackoff.captureStride(idleCaptureCount: count)
            XCTAssertGreaterThanOrEqual(stride, previous, "stride decreased at idleCaptureCount=\(count)")
            previous = stride
        }
    }

    func testChangeAfterIdleResetsToFullCadence() {
        var backoff = idledBackoff(captures: 400)
        XCTAssertEqual(backoff.idleCaptureCount, CotypingFocusPollBackoff.idleCaptureCountCap)
        XCTAssertGreaterThan(backoff.captureStride, 1)

        backoff.recordCapture(didChange: true)

        XCTAssertEqual(backoff.idleCaptureCount, 0)
        XCTAssertEqual(backoff.captureStride, 1)
    }

    func testExplicitRefreshResetReturnsToFullCadence() {
        var backoff = idledBackoff(captures: 30)
        XCTAssertEqual(backoff.captureStride, 10)

        backoff.reset()

        XCTAssertEqual(backoff.idleCaptureCount, 0)
        XCTAssertEqual(backoff.captureStride, 1)
    }

    func testMillisecondsSinceCaptureIsNilBeforeFirstCapture() {
        XCTAssertNil(CotypingFocusTracker.millisecondsSinceCapture(
            lastCaptureUptimeNanoseconds: nil,
            nowUptimeNanoseconds: 1_000_000))
    }

    func testMillisecondsSinceCaptureUsesCompletedCaptureTime() {
        XCTAssertEqual(CotypingFocusTracker.millisecondsSinceCapture(
            lastCaptureUptimeNanoseconds: 10_000_000,
            nowUptimeNanoseconds: 42_000_000), 32)
    }

    func testShouldRefreshCaptureWhenAgeUnknownOrOlderThanWindow() {
        XCTAssertTrue(CotypingFocusTracker.shouldRefreshCapture(
            lastCaptureUptimeNanoseconds: nil,
            nowUptimeNanoseconds: 42_000_000,
            maxAgeMilliseconds: 30))
        XCTAssertTrue(CotypingFocusTracker.shouldRefreshCapture(
            lastCaptureUptimeNanoseconds: 10_000_000,
            nowUptimeNanoseconds: 41_000_000,
            maxAgeMilliseconds: 30))
    }

    func testShouldReuseCaptureWithinFreshnessWindow() {
        XCTAssertFalse(CotypingFocusTracker.shouldRefreshCapture(
            lastCaptureUptimeNanoseconds: 10_000_000,
            nowUptimeNanoseconds: 40_000_000,
            maxAgeMilliseconds: 30))
        XCTAssertFalse(CotypingFocusTracker.shouldRefreshCapture(
            lastCaptureUptimeNanoseconds: 10_000_000,
            nowUptimeNanoseconds: 25_000_000,
            maxAgeMilliseconds: 30))
    }
}

// MARK: - Focus capability flicker gate

final class CotypingFocusCapabilityFlickerGateTests: XCTestCase {
    func testSingleBlockedFlickerOnSameElementIsSuppressed() {
        var gate = CotypingFocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedFocus(identity: "field-A"))

        XCTAssertEqual(
            gate.evaluate(blockedFocus(identity: "field-A")),
            .suppress(pendingBlockedReadCount: 1))
    }

    func testSupportedReturnAfterFlickerResetsCounter() {
        var gate = CotypingFocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedFocus(identity: "field-A"))
        _ = gate.evaluate(blockedFocus(identity: "field-A"))

        XCTAssertEqual(gate.evaluate(supportedFocus(identity: "field-A")), .apply)
        XCTAssertEqual(
            gate.evaluate(blockedFocus(identity: "field-A")),
            .suppress(pendingBlockedReadCount: 1))
    }

    func testSecondConsecutiveBlockedReadAppliesDowngrade() {
        var gate = CotypingFocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedFocus(identity: "field-A"))

        XCTAssertEqual(
            gate.evaluate(blockedFocus(identity: "field-A")),
            .suppress(pendingBlockedReadCount: 1))
        XCTAssertEqual(gate.evaluate(blockedFocus(identity: "field-A")), .apply)
    }

    func testBlockedOnDifferentElementAppliesImmediately() {
        var gate = CotypingFocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedFocus(identity: "field-A"))

        XCTAssertEqual(gate.evaluate(blockedFocus(identity: "field-B")), .apply)
    }

    func testUnsupportedIsNeverSuppressed() {
        var gate = CotypingFocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedFocus(identity: "field-A"))

        XCTAssertEqual(
            gate.evaluate(CotypingFocus(
                appName: "Finder", bundleID: "com.apple.finder",
                capability: .unsupported("No focused text field."), field: nil)),
            .apply)
    }

    func testSecureFieldBlockIsNeverSuppressed() {
        var gate = CotypingFocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedFocus(identity: "field-A"))

        XCTAssertEqual(
            gate.evaluate(CotypingFocus(
                appName: "Safari", bundleID: "com.apple.Safari",
                capability: .blocked("Secure field — never read."), field: nil,
                focusIdentityKey: "field-A")),
            .apply)
    }

    func testMissingBlockedIdentityAppliesImmediately() {
        var gate = CotypingFocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedFocus(identity: "field-A"))

        XCTAssertEqual(
            gate.evaluate(CotypingFocus(
                appName: "Safari", bundleID: "com.apple.Safari",
                capability: .blocked("Text selected."), field: nil)),
            .apply)
    }

    private func supportedFocus(identity: String?) -> CotypingFocus {
        let field = CotypingField(
            appName: "Safari", bundleID: "com.apple.Safari", processID: 1,
            role: "AXTextArea", focusIdentityKey: identity,
            precedingText: "hello", trailingText: "", selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true)
        return CotypingFocus(
            appName: "Safari", bundleID: "com.apple.Safari",
            capability: .supported, field: field, focusIdentityKey: identity)
    }

    private func blockedFocus(identity: String?) -> CotypingFocus {
        CotypingFocus(
            appName: "Safari", bundleID: "com.apple.Safari",
            capability: .blocked("Text selected."), field: nil,
            focusIdentityKey: identity)
    }
}

// MARK: - Settings codec

final class CotypingSettingsTests: XCTestCase {
    func testDefaultsDisabled() {
        XCTAssertFalse(AppSettings().cotypingEnabled)
    }

    func testRoundTripsCotypingFields() throws {
        var settings = AppSettings()
        settings.cotypingEnabled = true
        settings.cotypingUserName = "Ada"
        settings.cotypingMaxWords = 12
        settings.cotypingMultiLine = true
        settings.cotypingDebounceMs = 500
        settings.cotypingStreamSuggestionsWhileGenerating = true
        settings.cotypingFadeInSuggestions = false
        settings.cotypingFadeInDurationSeconds = 0.25
        settings.cotypingShowAcceptKeyHint = false
        settings.cotypingAcceptGranularity = .phrase
        settings.cotypingFullAcceptKey = .rightArrow
        settings.cotypingExcludedApps = "Terminal, 1Password"
        settings.cotypingSuggestInIntegratedTerminals = true
        settings.cotypingBuiltInModelID = ModelCatalog.bundledID
        settings.cotypingUseLocalLearning = false
        settings.cotypingLearningExamplesInPrompt = 5

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(decoded.cotypingEnabled)
        XCTAssertEqual(decoded.cotypingUserName, "Ada")
        XCTAssertEqual(decoded.cotypingMaxWords, 12)
        XCTAssertTrue(decoded.cotypingMultiLine)
        XCTAssertEqual(decoded.cotypingDebounceMs, 500)
        XCTAssertTrue(decoded.cotypingStreamSuggestionsWhileGenerating)
        XCTAssertFalse(decoded.cotypingFadeInSuggestions)
        XCTAssertEqual(decoded.cotypingFadeInDurationSeconds, 0.25, accuracy: 0.0001)
        XCTAssertFalse(decoded.cotypingShowAcceptKeyHint)
        XCTAssertEqual(decoded.cotypingAcceptGranularity, .phrase)
        XCTAssertEqual(decoded.cotypingFullAcceptKey, .rightArrow)
        XCTAssertEqual(decoded.cotypingExcludedAppList, ["Terminal", "1Password"])
        XCTAssertTrue(decoded.cotypingSuggestInIntegratedTerminals)
        XCTAssertEqual(decoded.cotypingBuiltInModelID, ModelCatalog.bundledID)
        XCTAssertFalse(decoded.cotypingUseLocalLearning)
        XCTAssertEqual(decoded.cotypingLearningExamplesInPrompt, 5)
    }

    func testTolerantDecodeKeepsOtherDefaults() throws {
        let data = #"{"cotypingEnabled":true}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(settings.cotypingEnabled)
        XCTAssertEqual(settings.cotypingMaxWords, AppSettings().cotypingMaxWords)
        XCTAssertEqual(settings.cotypingDebounceMs, AppSettings().cotypingDebounceMs)
        XCTAssertEqual(
            settings.cotypingStreamSuggestionsWhileGenerating,
            AppSettings().cotypingStreamSuggestionsWhileGenerating)
        XCTAssertTrue(settings.cotypingFadeInSuggestions)
        XCTAssertEqual(
            settings.cotypingFadeInDurationSeconds,
            AppSettings.defaultCotypingFadeInDurationSeconds,
            accuracy: 0.0001)
        XCTAssertTrue(settings.cotypingShowAcceptKeyHint)
        XCTAssertTrue(settings.cotypingUseLocalLearning)
        XCTAssertEqual(settings.cotypingBuiltInModelID, ModelCatalog.recommendedCotypingID)
        XCTAssertTrue(settings.menuBarOnly)
    }

    func testInProcessRuntimeDefaultsOn() {
        XCTAssertTrue(AppSettings().cotypingInProcessRuntime)
    }

    func testInProcessRuntimeRoundTrips() throws {
        var settings = AppSettings()
        settings.cotypingInProcessRuntime = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(decoded.cotypingInProcessRuntime)
    }

    func testTolerantDecodeDefaultsInProcessRuntimeOn() throws {
        // A saved blob predating the flag must decode with the default (true).
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(decoded.cotypingInProcessRuntime)
    }

    func testDefaultsMirrorCotypistLengthAndDebounce() {
        let settings = AppSettings()
        XCTAssertEqual(settings.cotypingMaxWords, 20)
        XCTAssertEqual(settings.cotypingDebounceMs, 20)
        XCTAssertFalse(settings.cotypingStreamSuggestionsWhileGenerating)
        XCTAssertTrue(settings.cotypingFadeInSuggestions)
        XCTAssertEqual(settings.cotypingFadeInDurationSeconds, 0.15, accuracy: 0.0001)
        XCTAssertTrue(settings.cotypingShowAcceptKeyHint)
        XCTAssertEqual(settings.cotypingMaxResponseTokens, 26)
    }

    func testFadeDurationClampsToCotypistBand() throws {
        let tooLow = #"{"cotypingFadeInDurationSeconds":0.001}"#.data(using: .utf8)!
        XCTAssertEqual(
            try JSONDecoder().decode(AppSettings.self, from: tooLow).cotypingFadeInDurationSeconds,
            AppSettings.minimumCotypingFadeInDurationSeconds,
            accuracy: 0.0001)

        let tooHigh = #"{"cotypingFadeInDurationSeconds":2.0}"#.data(using: .utf8)!
        XCTAssertEqual(
            try JSONDecoder().decode(AppSettings.self, from: tooHigh).cotypingFadeInDurationSeconds,
            AppSettings.maximumCotypingFadeInDurationSeconds,
            accuracy: 0.0001)
    }

    func testMaxResponseTokensMirrorCotypistBudget() {
        var settings = AppSettings()
        settings.cotypingMaxWords = 2
        XCTAssertEqual(settings.cotypingMaxResponseTokens, 5)   // floor
        settings.cotypingMaxWords = 8
        XCTAssertEqual(settings.cotypingMaxResponseTokens, 11)  // ceil(8 * 1.3)
        settings.cotypingMaxWords = 20
        XCTAssertEqual(settings.cotypingMaxResponseTokens, 26)  // ceil(20 * 1.3)
        settings.cotypingMultiLine = true
        XCTAssertEqual(settings.cotypingMaxResponseTokens, 52)  // doubled for multiline
        settings.cotypingMaxWords = 100
        XCTAssertEqual(settings.cotypingMaxResponseTokens, 120) // cap
    }
}

// MARK: - Stale-field guard (continuation)

final class CotypingContinuationTests: XCTestCase {
    private func field(_ preceding: String, pid: pid_t = 5) -> CotypingField {
        CotypingField(
            appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", processID: pid,
            role: "AXTextArea", precedingText: preceding, trailingText: "",
            selectionLength: 0, caretRect: .zero, isSecure: false, caretIsExact: true)
    }

    private func session(_ preceding: String, pid: pid_t = 5) -> CotypingSession {
        CotypingSession(field: field(preceding, pid: pid), fullText: " up on the deck")
    }

    func testSameUntouchedFieldIsContinuation() {
        XCTAssertTrue(CotypingCoordinator.isContinuation(of: session("I wanted to follow"), liveField: field("I wanted to follow")))
    }

    func testFieldGrownByAcceptedWordsIsContinuation() {
        // After accepting a word, the live preceding text only grows.
        XCTAssertTrue(CotypingCoordinator.isContinuation(of: session("I wanted to follow"), liveField: field("I wanted to follow up")))
    }

    func testDifferentFieldSameProcessIsNotContinuation() {
        // Another compose box in the same app (same PID) must NOT match.
        XCTAssertFalse(CotypingCoordinator.isContinuation(of: session("I wanted to follow"), liveField: field("Reply to the thread")))
    }

    func testCappedLongFieldShiftAfterAcceptedWordIsContinuation() {
        let previous = String(repeating: "a", count: 4096)
        let live = String(previous.dropFirst(3)) + " up"
        XCTAssertTrue(CotypingCoordinator.isContinuation(of: session(previous), liveField: field(live)))
    }

    func testDifferentProcessIsNotContinuation() {
        XCTAssertFalse(CotypingCoordinator.isContinuation(of: session("I wanted to follow", pid: 5), liveField: field("I wanted to follow", pid: 99)))
    }

    func testNoLiveFieldIsNotContinuation() {
        XCTAssertFalse(CotypingCoordinator.isContinuation(of: session("I wanted to follow"), liveField: nil))
    }

    func testCurrentGenerationTargetRequiresSameContentAndIdentity() {
        var original = field("I wanted to follow")
        original.focusIdentityKey = "field-a"
        var live = original

        XCTAssertTrue(CotypingCoordinator.isCurrentGenerationTarget(original, liveField: live))

        live.precedingText += " up"
        XCTAssertFalse(CotypingCoordinator.isCurrentGenerationTarget(original, liveField: live))

        live = original
        live.focusIdentityKey = "field-b"
        XCTAssertFalse(CotypingCoordinator.isCurrentGenerationTarget(original, liveField: live))
    }

    func testCurrentGenerationTargetAllowsMissingFocusIdentityButStillRequiresAnchorIdentity() {
        var original = field("I wanted to follow")
        original.windowTitle = "Draft"
        var live = original
        live.focusIdentityKey = nil

        XCTAssertTrue(CotypingCoordinator.isCurrentGenerationTarget(original, liveField: live))

        live.windowTitle = "Other Draft"
        XCTAssertFalse(CotypingCoordinator.isCurrentGenerationTarget(original, liveField: live))
    }

    func testPublishedTypingAdvancesSuggestionTail() throws {
        let advanced = try XCTUnwrap(CotypingCoordinator.sessionAdvancedByPublishedTyping(
            session("I wanted to follow"),
            liveField: field("I wanted to follow up")))

        XCTAssertEqual(advanced.consumedCount, 3)
        XCTAssertEqual(advanced.remainingText, " on the deck")
        XCTAssertEqual(advanced.field.precedingText, "I wanted to follow up")
    }

    func testPublishedTypingHonorsAlreadyAcceptedPrefix() throws {
        let accepted = session("I wanted to follow").advanced(by: 3)
        let advanced = try XCTUnwrap(CotypingCoordinator.sessionAdvancedByPublishedTyping(
            accepted,
            liveField: field("I wanted to follow up on")))

        XCTAssertEqual(advanced.consumedCount, 6)
        XCTAssertEqual(advanced.remainingText, " the deck")
    }

    func testPublishedTypingDoesNotAdvanceMismatchedText() {
        XCTAssertNil(CotypingCoordinator.sessionAdvancedByPublishedTyping(
            session("I wanted to follow"),
            liveField: field("I wanted to follow nope")))
    }

    func testStaleAcceptanceEchoDropsRepeatOfAcceptedTailWhileFieldUnchanged() {
        XCTAssertTrue(CotypingCoordinator.isStaleAcceptanceEcho(
            resultText: " today",
            acceptedChunk: " today",
            currentPrecedingText: "what's on your mind",
            acceptedPrecedingText: "what's on your mind"))
    }

    func testStaleAcceptanceEchoToleratesLeadingWhitespaceDifference() {
        XCTAssertTrue(CotypingCoordinator.isStaleAcceptanceEcho(
            resultText: "today",
            acceptedChunk: " today",
            currentPrecedingText: "what's on your mind",
            acceptedPrecedingText: "what's on your mind"))
    }

    func testStaleAcceptanceEchoAllowsSuggestionOnceInsertPublished() {
        XCTAssertFalse(CotypingCoordinator.isStaleAcceptanceEcho(
            resultText: " today",
            acceptedChunk: " today",
            currentPrecedingText: "what's on your mind today",
            acceptedPrecedingText: "what's on your mind"))
    }

    func testStaleAcceptanceEchoAllowsGenuinelyDifferentContinuation() {
        XCTAssertFalse(CotypingCoordinator.isStaleAcceptanceEcho(
            resultText: " tomorrow",
            acceptedChunk: " today",
            currentPrecedingText: "what's on your mind",
            acceptedPrecedingText: "what's on your mind"))
    }

    func testStaleAcceptanceEchoIgnoresWhitespaceOnlyChunk() {
        XCTAssertFalse(CotypingCoordinator.isStaleAcceptanceEcho(
            resultText: " ",
            acceptedChunk: " ",
            currentPrecedingText: "what's on your mind",
            acceptedPrecedingText: "what's on your mind"))
    }

    func testOptimisticFieldAfterAcceptanceAppendsInsertedText() {
        let optimistic = CotypingCoordinator.optimisticFieldAfterAcceptance(
            field("what's on your mind"),
            insertionText: " today")

        XCTAssertEqual(optimistic.precedingText, "what's on your mind today")
        XCTAssertEqual(optimistic.trailingText, "")
        XCTAssertEqual(optimistic.selectionLength, 0)
    }

    func testOptimisticFieldAfterAcceptanceDropsForwardDeletedTrailingOverlap() {
        var live = field("rec")
        live.trailingText = "eive the files"

        let optimistic = CotypingCoordinator.optimisticFieldAfterAcceptance(
            live,
            insertionText: "eive",
            deletingTrailingCharacters: 4)

        XCTAssertEqual(optimistic.precedingText, "receive")
        XCTAssertEqual(optimistic.trailingText, " the files")
    }
}

// MARK: - App/window (surface) context

final class CotypingSurfaceContextTests: XCTestCase {
    func testClassifier() {
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.apple.mail"), .email)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.google.Chrome"), .browser)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.apple.dt.Xcode"), .codeEditor)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.apple.Terminal"), .terminal)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.mitchellh.ghostty"), .terminal)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "io.rio.terminal"), .terminal)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.microsoft.VSCode", isIntegratedTerminal: true), .terminal)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.acme.unknown"), .other)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: nil), .other)
    }

    func testIntegratedTerminalClassDetection() {
        XCTAssertTrue(CotypingSurfaceClassifier.isIntegratedTerminal(domClassList: ["xterm-helper-textarea"]))
        XCTAssertTrue(CotypingSurfaceClassifier.isIntegratedTerminal(domClassList: ["xterm-screen"]))
        XCTAssertFalse(CotypingSurfaceClassifier.isIntegratedTerminal(domClassList: ["monaco-editor"]))
        XCTAssertFalse(CotypingSurfaceClassifier.isIntegratedTerminal(domClassList: []))
    }

    func testSuppressedInCodeEditorAndTerminal() {
        XCTAssertNil(CotypingSurfaceComposer.compose(
            appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "main.swift", fieldPlaceholder: nil))
        XCTAssertNil(CotypingSurfaceComposer.compose(
            appName: "Terminal", bundleID: "com.apple.Terminal", windowTitle: "bash", fieldPlaceholder: nil))
        XCTAssertNil(CotypingSurfaceComposer.compose(
            appName: "Code",
            bundleID: "com.microsoft.VSCode",
            windowTitle: "Cloud Shell",
            fieldPlaceholder: nil,
            isIntegratedTerminal: true))
    }

    func testGenericAppWithNoCuesIsNil() {
        XCTAssertNil(CotypingSurfaceComposer.compose(
            appName: "SomeApp", bundleID: "com.acme.app", windowTitle: nil, fieldPlaceholder: nil))
    }

    func testGenericUntitledDocumentDoesNotBecomeContext() {
        XCTAssertNil(CotypingSurfaceComposer.compose(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            windowTitle: "Untitled - TextEdit",
            fieldPlaceholder: nil))
    }

    func testEmailPrefaceLines() throws {
        let surface = try XCTUnwrap(CotypingSurfaceComposer.compose(
            appName: "Mail", bundleID: "com.apple.mail", windowTitle: "Re: Q3 planning", fieldPlaceholder: nil))
        let lines = CotypingSurfaceComposer.prefaceLines(for: surface)
        XCTAssertEqual(lines.first, "An email being written in Mail.")
        XCTAssertTrue(lines.contains("The window is titled \"Re: Q3 planning\"."))
    }

    func testTitleStripsAppSuffix() {
        XCTAssertEqual(CotypingSurfaceComposer.sanitizedTitle("Inbox - Gmail", applicationName: "Gmail"), "Inbox")
        XCTAssertEqual(CotypingSurfaceComposer.sanitizedTitle("Notes — Pages", applicationName: "Pages"), "Notes")
    }

    func testChatPlaceholderLine() throws {
        let surface = try XCTUnwrap(CotypingSurfaceComposer.compose(
            appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", windowTitle: nil, fieldPlaceholder: "Message #general"))
        let lines = CotypingSurfaceComposer.prefaceLines(for: surface)
        XCTAssertEqual(lines.first, "A chat message being typed in Slack.")
        XCTAssertTrue(lines.contains("The text field is labeled \"Message #general\"."))
    }

    func testPromptPutsSurfaceFirst() {
        let prompt = CotypingPromptRenderer.prompt(
            prefixText: "Thanks for", surfaceLines: ["An email being written in Mail."], userName: "Sam")
        XCTAssertEqual(prompt, "An email being written in Mail.\nWritten by Sam.\n\nThanks for")
    }

    func testRequestBuilderFoldsAppContextWhenEnabled() throws {
        let field = CotypingField(
            appName: "Mail", bundleID: "com.apple.mail", processID: 1, role: "AXTextArea",
            precedingText: "Hi Sarah,", trailingText: "", selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true,
            windowTitle: "Re: Q3 planning", fieldPlaceholder: nil)
        let on = CotypingPersonalization(
            userName: nil, styleNote: nil, languageHint: nil, isMultiLine: false, appContextEnabled: true)
        let req = try XCTUnwrap(CotypingRequestBuilder.build(field: field, config: .standard, personalization: on, generation: 0))
        XCTAssertTrue(req.prompt.contains("An email being written in Mail."))
        XCTAssertTrue(req.prompt.contains("Re: Q3 planning"))
        XCTAssertTrue(req.prompt.hasSuffix("Hi Sarah,"))

        let off = CotypingPersonalization(
            userName: nil, styleNote: nil, languageHint: nil, isMultiLine: false, appContextEnabled: false)
        let reqOff = try XCTUnwrap(CotypingRequestBuilder.build(field: field, config: .standard, personalization: off, generation: 0))
        XCTAssertEqual(reqOff.prompt, "Hi Sarah,")
    }

    func testAppContextSettingDefaultsOnAndRoundTrips() throws {
        XCTAssertTrue(AppSettings().cotypingUseAppContext)
        var s = AppSettings()
        s.cotypingUseAppContext = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertFalse(decoded.cotypingUseAppContext)
        XCTAssertFalse(decoded.cotypingPersonalization.appContextEnabled)
    }
}

// MARK: - Mid-word continuation (complete the word being typed)

final class CotypingMidWordTests: XCTestCase {
    private func request(prefix: String, trailing: String, force: Bool) -> CotypingRequest {
        CotypingRequest(
            prompt: prefix, prefixText: prefix, trailingText: trailing, isMultiLine: false,
            maxTokens: 24, temperature: 0.1, topP: 0.7, topK: 20, minP: 0.08,
            repeatPenalty: 1.05, seed: 0, generation: 0, forceWordContinuation: force)
    }

    func testForceOnlyWhenStrictlyInsideWord() {
        XCTAssertTrue(CotypingMidWord.shouldForceContinuation(precedingText: "rec", trailingText: "eive"))
        XCTAssertFalse(CotypingMidWord.shouldForceContinuation(precedingText: "rec", trailingText: ""))
        XCTAssertFalse(CotypingMidWord.shouldForceContinuation(precedingText: "rec", trailingText: " more"))
        XCTAssertFalse(CotypingMidWord.shouldForceContinuation(precedingText: "rec", trailingText: "."))
        XCTAssertFalse(CotypingMidWord.shouldForceContinuation(precedingText: "rec ", trailingText: "x"))
        XCTAssertFalse(CotypingMidWord.shouldForceContinuation(precedingText: "", trailingText: "x"))
    }

    func testCurrentPartialWord() {
        XCTAssertEqual(CotypingMidWord.currentPartialWord(in: "I want to rec"), "rec")
        XCTAssertEqual(CotypingMidWord.currentPartialWord(in: "I want to "), "")
        XCTAssertEqual(CotypingMidWord.currentPartialWord(in: "price is 42"), "42")
        XCTAssertEqual(CotypingMidWord.currentPartialWord(in: "end."), "")
    }

    func testStripsRetypedPartialWordSoItCompletes() {
        // Typed "rec"; the model echoed the whole word — keep only the new tail.
        let result = CotypingTextNormalizer.normalize(
            "receive the package", for: request(prefix: "I want to rec", trailing: "", force: false))
        XCTAssertEqual(result, "eive the package")
    }

    func testNaturalContinuationUnchanged() {
        let result = CotypingTextNormalizer.normalize(
            "eive the package", for: request(prefix: "I want to rec", trailing: "", force: false))
        XCTAssertEqual(result, "eive the package")
    }

    func testForceContinuationStripsLeadingSpace() {
        let forced = CotypingTextNormalizer.normalize(
            " ord", for: request(prefix: "rec", trailing: "ord", force: true))
        XCTAssertEqual(forced, "ord")
    }

    func testAcceptedMidWordOverlapDeletesExistingTrailingFragment() {
        XCTAssertEqual(CotypingMidWord.acceptedTrailingOverlapCount(acceptedText: "ord", trailingText: "ord"), 3)
        XCTAssertEqual(CotypingMidWord.acceptedTrailingOverlapCount(acceptedText: "ording", trailingText: "ord"), 3)
        XCTAssertEqual(CotypingMidWord.acceptedTrailingOverlapCount(acceptedText: "or", trailingText: "ord"), 2)
    }

    func testAcceptedMidWordOverlapIgnoresWeakSharedPrefix() {
        XCTAssertEqual(CotypingMidWord.acceptedTrailingOverlapCount(acceptedText: "operate", trailingText: "ord"), 0)
    }

    func testForceContinuationSuppressesIncompatibleWordTail() {
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            "ode the following code in C++:",
            for: request(prefix: "Please rec", trailing: "eive the files when ready.", force: true))
        XCTAssertEqual(detailed.text, "")
        XCTAssertEqual(detailed.suppression, .unsafeToInsert)
    }

    func testNoForceKeepsModelSpacingAtWordEnd() {
        // Not strictly inside a word: the model's "this word is done" call stands.
        let result = CotypingTextNormalizer.normalize(
            " document", for: request(prefix: "rec", trailing: "", force: false))
        XCTAssertEqual(result, " document")
    }

    func testDoesNotStripShortPartialWord() {
        let result = CotypingTextNormalizer.normalize(
            "am late", for: request(prefix: "I a", trailing: "", force: false))
        XCTAssertEqual(result, "am late")
    }
}

// MARK: - Autocorrect

final class CotypingAutocorrectTests: XCTestCase {
    func testExtractTrailingWord() {
        XCTAssertEqual(CotypingWord.extract(from: "I want to teh")?.word, "teh")
        XCTAssertNil(CotypingWord.extract(from: "I want to "))
        XCTAssertNil(CotypingWord.extract(from: "see http://x.com"))
        XCTAssertNil(CotypingWord.extract(from: "the API"))
        XCTAssertNil(CotypingWord.extract(from: "a"))
    }

    func testExtractTrailingWordToleratesOneSpace() {
        let result = CotypingWord.extractTrailingWord(from: "I want to teh ")
        XCTAssertEqual(result?.result.word, "teh")
        XCTAssertEqual(result?.trailingSpaceCount, 1)
        XCTAssertNil(CotypingWord.extractTrailingWord(from: "I want to teh  "))
    }

    func testCaseTransfer() {
        XCTAssertEqual(CotypingCaseTransfer.applying(caseOf: "Teh", to: "the"), "The")
        XCTAssertEqual(CotypingCaseTransfer.applying(caseOf: "HTE", to: "the"), "THE")
        XCTAssertEqual(CotypingCaseTransfer.applying(caseOf: "teh", to: "the"), "the")
    }

    func testTypoGateOffersCorrection() {
        let decision = CotypingTypoGate.resolve(
            precedingText: "I want to teh", enabled: true,
            isTypo: { $0 == "teh" }, bestCorrection: { $0 == "teh" ? "the" : nil })
        XCTAssertEqual(decision, .offerCorrection(word: "teh", correctedWord: "the"))
    }

    func testTypoGateSuppressesWhenNoCorrection() {
        let decision = CotypingTypoGate.resolve(
            precedingText: "asdfgh", enabled: true,
            isTypo: { _ in true }, bestCorrection: { _ in nil })
        XCTAssertEqual(decision, .suppress)
    }

    func testTypoGateProceedsWhenWordIsFine() {
        let decision = CotypingTypoGate.resolve(
            precedingText: "I want to the", enabled: true,
            isTypo: { _ in false }, bestCorrection: { _ in nil })
        XCTAssertEqual(decision, .proceed)
    }

    func testTypoGateProceedsWhenDisabled() {
        let decision = CotypingTypoGate.resolve(
            precedingText: "teh", enabled: false,
            isTypo: { _ in true }, bestCorrection: { _ in "the" })
        XCTAssertEqual(decision, .proceed)
    }

    func testCorrectionPlan() {
        let plan = CotypingCorrectionPlan.plan(
            precedingText: "I want to teh", expectedTypo: "teh", correctedWord: "the")
        XCTAssertEqual(plan?.deletingCharacters, 3)
        XCTAssertEqual(plan?.replacementText, "the")
    }

    func testCorrectionPlanPreservesTrailingSpace() {
        let plan = CotypingCorrectionPlan.plan(
            precedingText: "I want to teh ", expectedTypo: "teh", correctedWord: "the")
        XCTAssertEqual(plan?.deletingCharacters, 4)
        XCTAssertEqual(plan?.replacementText, "the ")
    }

    func testCorrectionPlanFailsWhenWordChanged() {
        XCTAssertNil(CotypingCorrectionPlan.plan(
            precedingText: "I want to the", expectedTypo: "teh", correctedWord: "the"))
    }
}

// MARK: - Streaming SSE parsing

final class CotypingStreamingTests: XCTestCase {
    func testParsesTextDelta() {
        XCTAssertEqual(cotypingParseSSEDelta(#"data: {"choices":[{"text":"eive"}]}"#), "eive")
    }

    func testIgnoresDoneSentinel() {
        XCTAssertNil(cotypingParseSSEDelta("data: [DONE]"))
    }

    func testIgnoresNonDataLines() {
        XCTAssertNil(cotypingParseSSEDelta(""))
        XCTAssertNil(cotypingParseSSEDelta(": keep-alive"))
        XCTAssertNil(cotypingParseSSEDelta("event: message"))
    }

    func testEmptyTextDeltaIsEmptyNotNil() {
        XCTAssertEqual(cotypingParseSSEDelta(#"data: {"choices":[{"text":""}]}"#), "")
    }
}

// MARK: - Phrase acceptance, accept options, context prompt

final class CotypingWordAcceptanceTests: XCTestCase {
    func testLatinAcceptanceUnchangedBySpacelessBranch() {
        XCTAssertEqual(CotypingCoordinator.nextWord(in: "hello world"), "hello ")
        XCTAssertEqual(CotypingCoordinator.nextWord(in: "don't stop now"), "don't ")
        XCTAssertEqual(CotypingCoordinator.nextWord(in: "U.S.A today"), "U.S.A ")
        XCTAssertEqual(CotypingCoordinator.nextWord(in: "1.5 times"), "1.5 ")
        XCTAssertEqual(CotypingCoordinator.nextWord(in: "caf\u{00e9} Ren\u{00e9}"), "caf\u{00e9} ")
        XCTAssertEqual(CotypingCoordinator.nextWord(in: "world \u{4f60}\u{597d}"), "world ")
    }

    func testChineseRunSegmentsInsteadOfAcceptingWholeTail() {
        let run = "\u{4f60}\u{597d}\u{4e16}\u{754c}"
        let chunk = CotypingCoordinator.nextWord(in: run)
        XCTAssertFalse(chunk.isEmpty)
        XCTAssertTrue(run.hasPrefix(chunk))
        XCTAssertLessThan(chunk.count, run.count)
    }

    func testJapaneseRunSegmentsInsteadOfAcceptingWholeTail() {
        let run = "\u{4eca}\u{65e5}\u{306f}\u{3044}\u{3044}\u{5929}\u{6c17}\u{3067}\u{3059}"
        let chunk = CotypingCoordinator.nextWord(in: run)
        XCTAssertFalse(chunk.isEmpty)
        XCTAssertTrue(run.hasPrefix(chunk))
        XCTAssertLessThan(chunk.count, run.count)
    }

    func testThaiRunSegmentsInsteadOfAcceptingWholeTail() {
        let run = "\u{0e2a}\u{0e27}\u{0e31}\u{0e2a}\u{0e14}\u{0e35}\u{0e04}\u{0e23}\u{0e31}\u{0e1a}"
        let chunk = CotypingCoordinator.nextWord(in: run)
        XCTAssertFalse(chunk.isEmpty)
        XCTAssertTrue(run.hasPrefix(chunk))
        XCTAssertLessThan(chunk.count, run.count)
    }

    func testBindsTrailingCJKPunctuationToWord() {
        XCTAssertEqual(
            CotypingCoordinator.nextWord(in: "\u{8cc7}\u{6599}\u{3001}\u{5185}\u{5bb9}"),
            "\u{8cc7}\u{6599}\u{3001}")
    }

    func testPeelsLeadingCJKPunctuationRun() {
        XCTAssertEqual(
            CotypingCoordinator.nextWord(in: "\u{3001}\u{7406}\u{89e3}\u{3057}\u{3001}\u{305d}\u{306e}\u{5185}\u{5bb9}"),
            "\u{3001}")
        XCTAssertEqual(
            CotypingCoordinator.nextWord(in: "\u{3002}\u{300d}\u{6b21}\u{306e}\u{6587}"),
            "\u{3002}\u{300d}")
        XCTAssertEqual(
            CotypingCoordinator.nextWord(in: "\u{300c}\u{5206}\u{304b}\u{3063}\u{305f}\u{300d}\u{3068}\u{8a00}\u{3063}\u{305f}"),
            "\u{300c}")
    }
}

final class CotypingPhraseTests: XCTestCase {
    func testDoesNotStopAtAsciiComma() {
        XCTAssertEqual(CotypingCoordinator.nextPhrase(in: "Hi Sarah, thanks."), "Hi Sarah, thanks.")
    }
    func testWholeTextWhenNoBoundary() {
        XCTAssertEqual(CotypingCoordinator.nextPhrase(in: "the quick brown"), "the quick brown")
    }
    func testStopsAtSentenceEnd() {
        XCTAssertEqual(CotypingCoordinator.nextPhrase(in: "done. next thing"), "done. ")
    }
    func testStopsAtNewline() {
        XCTAssertEqual(CotypingCoordinator.nextPhrase(in: "done\nnext thing"), "done\n")
    }
    func testCJKClauseBoundary() {
        XCTAssertEqual(
            CotypingCoordinator.nextPhrase(in: "\u{8cc7}\u{6599}\u{3092}\u{8aad}\u{307f}\u{3001}\u{6b21}\u{3078}"),
            "\u{8cc7}\u{6599}\u{3092}\u{8aad}\u{307f}\u{3001}")
        XCTAssertEqual(
            CotypingCoordinator.nextPhrase(in: "\u{4f60}\u{597d}\u{3002}\u{518d}\u{89c1}"),
            "\u{4f60}\u{597d}\u{3002}")
    }
}

final class CotypingAcceptOptionsTests: XCTestCase {
    func testDefaults() {
        let settings = AppSettings()
        XCTAssertEqual(settings.cotypingAcceptGranularity, .word)
        XCTAssertEqual(settings.cotypingAcceptKey, .tab)
        XCTAssertEqual(settings.cotypingFullAcceptKey, .backtick)
    }
    func testKeyCodes() {
        XCTAssertEqual(CotypingAcceptKey.tab.keyCode, 48)
        XCTAssertEqual(CotypingAcceptKey.rightArrow.keyCode, 124)
        XCTAssertEqual(CotypingFullAcceptKey.backtick.keyCode, 50)
        XCTAssertNil(CotypingFullAcceptKey.off.keyCode)
    }
}

final class CotypingContextPromptTests: XCTestCase {
    func testLanguageAndNotesEnterPreface() {
        let prompt = CotypingPromptRenderer.prompt(
            prefixText: "Dear team",
            languageHint: "The text is usually written in German.",
            extendedContext: "Acme = our product")
        XCTAssertTrue(prompt.contains("The text is usually written in German."))
        XCTAssertTrue(prompt.contains("Notes the writer keeps in mind: Acme = our product"))
        XCTAssertTrue(prompt.hasSuffix("Dear team"))
    }

    func testPersonalizationDerivesLanguageAndNotes() {
        var settings = AppSettings()
        settings.cotypingLanguages = "English, German"
        settings.cotypingExtendedContext = "Acme = our product"
        let personalization = settings.cotypingPersonalization
        XCTAssertEqual(personalization.languageHint, "The text is usually written in English, German.")
        XCTAssertEqual(personalization.extendedContext, "Acme = our product")
    }
}

// MARK: - Emoji autocomplete + adaptive debounce

final class CotypingEmojiTests: XCTestCase {
    func testOpenPrefixMatch() {
        let match = CotypingEmoji.match(trailing: "I love :roc")
        XCTAssertEqual(match?.glyph, "\u{1f680}")
        XCTAssertEqual(match?.shortcode, "rocket")
        XCTAssertEqual(match?.typedLength, 4)
    }

    func testClosedExactMatch() {
        let match = CotypingEmoji.match(trailing: "ship it :rocket:")
        XCTAssertEqual(match?.glyph, "\u{1f680}")
        XCTAssertEqual(match?.typedLength, 8)
    }

    func testSynonymResolves() {
        XCTAssertEqual(CotypingEmoji.match(trailing: "haha :lol")?.glyph, "\u{1f602}")
    }

    func testRequiresWordBoundary() {
        XCTAssertNil(CotypingEmoji.match(trailing: "http://exa"))
        XCTAssertNil(CotypingEmoji.match(trailing: "12:30"))
        XCTAssertNil(CotypingEmoji.match(trailing: "foo::bar"))
    }

    func testNoMatchForUnknown() {
        XCTAssertNil(CotypingEmoji.match(trailing: "see :zzzzz"))
    }

    func testTooShortOpenQuery() {
        XCTAssertNil(CotypingEmoji.match(trailing: "a :x"))
    }

    func testTrailingTokenLength() {
        XCTAssertEqual(CotypingEmoji.trailingTokenLength(in: "I love :roc"), 4)
        XCTAssertEqual(CotypingEmoji.trailingTokenLength(in: "go :rocket:"), 8)
        XCTAssertNil(CotypingEmoji.trailingTokenLength(in: "no token here"))
    }

    func testEmojiSettingDefaultsOn() {
        XCTAssertTrue(AppSettings().cotypingEmoji)
    }
}

final class CotypingSeamGuardTests: XCTestCase {
    func testAllowsNormalCompletion() {
        let verdict = CotypingSeamGuard.verdict(
            precedingText: "I wanted to follow",
            completion: " up tomorrow",
            isKnownWord: { _ in true })
        XCTAssertEqual(verdict, .allow)
    }

    func testRejectsFreshJunkPunctuationRun() {
        let verdict = CotypingSeamGuard.verdict(
            precedingText: "Thanks",
            completion: " !!!!",
            isKnownWord: { _ in true })
        XCTAssertEqual(verdict, .junkPunctuationRun)
    }

    func testAllowsExistingDividerContinuation() {
        let verdict = CotypingSeamGuard.verdict(
            precedingText: "--",
            completion: "----",
            isKnownWord: { _ in true })
        XCTAssertEqual(verdict, .allow)
    }

    func testRejectsMidWordMisspelling() {
        let verdict = CotypingSeamGuard.verdict(
            precedingText: "I am gre",
            completion: "atful",
            isKnownWord: { $0 == "grateful" })
        XCTAssertEqual(verdict, .seamMisspelling(word: "greatful"))
    }

    func testAllowsKnownMidWordJoin() {
        let verdict = CotypingSeamGuard.verdict(
            precedingText: "after",
            completion: "noon",
            isKnownWord: { $0 == "afternoon" })
        XCTAssertEqual(verdict, .allow)
    }

    func testStreamedPartialUsesPunctuationOnlyGuard() {
        XCTAssertFalse(CotypingSeamGuard.allowsStreamedPartial(
            precedingText: "Thanks",
            completion: " !!!!"))
        XCTAssertTrue(CotypingSeamGuard.allowsStreamedPartial(
            precedingText: "I am gre",
            completion: "atful"))
    }
}

final class CotypingDebounceTests: XCTestCase {
    func testCotypistParityFloorIsTwentyMilliseconds() {
        XCTAssertEqual(CotypingDebouncePolicy.minimumMilliseconds, 20)
        XCTAssertEqual(CotypingDebouncePolicy.milliseconds(lastLatencyMilliseconds: nil, configured: 20), 20)
    }

    func testConfiguredBelowFloorIsClamped() {
        XCTAssertEqual(CotypingDebouncePolicy.milliseconds(lastLatencyMilliseconds: nil, configured: 5), 20)
    }

    func testNoLatencyUsesConfigured() {
        XCTAssertEqual(CotypingDebouncePolicy.milliseconds(lastLatencyMilliseconds: nil, configured: 150), 150)
    }
    func testFastKeepsConfiguredFloor() {
        XCTAssertEqual(CotypingDebouncePolicy.milliseconds(lastLatencyMilliseconds: 120, configured: 150), 150)
    }
    func testSlowBacksOff() {
        XCTAssertEqual(CotypingDebouncePolicy.milliseconds(lastLatencyMilliseconds: 800, configured: 150), 400)
    }
    func testBackoffCapped() {
        XCTAssertEqual(CotypingDebouncePolicy.milliseconds(lastLatencyMilliseconds: 4000, configured: 150), 600)
    }
    func testHostPublishWaitConsumesDebounceWindow() {
        XCTAssertEqual(
            CotypingDebouncePolicy.milliseconds(
                lastLatencyMilliseconds: nil,
                configured: 150,
                consumedDelayMilliseconds: 40),
            110)
    }
    func testHostPublishWaitCanExhaustDebounceWindow() {
        XCTAssertEqual(
            CotypingDebouncePolicy.milliseconds(
                lastLatencyMilliseconds: 800,
                configured: 150,
                consumedDelayMilliseconds: 450),
            0)
    }
}

// MARK: - Inline macros

final class CotypingMacroTests: XCTestCase {
    /// Deterministic engine: fixed clock (2026-06-23 14:30 UTC, a Tuesday), UTC
    /// calendar, en_US locale, and an injected RNG/UUID.
    private func fixedEngine(random: @escaping (ClosedRange<Int>) -> Int = { $0.lowerBound }) -> CotypingMacro.Engine {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 23; comps.hour = 14; comps.minute = 30
        let now = calendar.date(from: comps)!
        var engine = CotypingMacro.Engine()
        engine.now = { now }
        engine.calendar = calendar
        engine.locale = Locale(identifier: "en_US")
        engine.random = random
        engine.uuid = { "FIXED-UUID" }
        return engine
    }

    // Arithmetic
    func testArithmeticPreviewAndInsertion() {
        let result = fixedEngine().evaluate("5+5")
        XCTAssertEqual(result?.preview, "= 10")
        XCTAssertEqual(result?.insertion, "10")
    }
    func testArithmeticPrecedence() {
        XCTAssertEqual(fixedEngine().evaluate("3+4*2")?.insertion, "11")
        XCTAssertEqual(fixedEngine().evaluate("(1+2)*3")?.insertion, "9")
    }
    func testArithmeticDivisionAndPower() {
        XCTAssertEqual(fixedEngine().evaluate("10/4")?.insertion, "2.5")
        XCTAssertEqual(fixedEngine().evaluate("2^10")?.insertion, "1024")
    }
    func testArithmeticPercentAndMultiplyAlias() {
        XCTAssertEqual(fixedEngine().evaluate("200*10%")?.insertion, "20")
        XCTAssertEqual(fixedEngine().evaluate("5x5")?.insertion, "25")
    }
    func testArithmeticTrailingEquals() {
        XCTAssertEqual(fixedEngine().evaluate("5+5=")?.insertion, "10")
    }
    func testBareNumberIsNotAMacro() {
        XCTAssertNil(fixedEngine().evaluate("5"))
        XCTAssertNil(fixedEngine().evaluate("notamacro"))
    }

    // Date / time
    func testDateToday() {
        XCTAssertEqual(fixedEngine().evaluate("today(iso)")?.insertion, "2026-06-23")
        XCTAssertEqual(fixedEngine().evaluate("tdy(iso)")?.insertion, "2026-06-23")
    }
    func testDateTomorrowYesterday() {
        XCTAssertEqual(fixedEngine().evaluate("tomorrow(iso)")?.insertion, "2026-06-24")
        XCTAssertEqual(fixedEngine().evaluate("yesterday(iso)")?.insertion, "2026-06-22")
    }
    func testDateRelativeOffsets() {
        XCTAssertEqual(fixedEngine().evaluate("+3d(iso)")?.insertion, "2026-06-26")
        XCTAssertEqual(fixedEngine().evaluate("+1w(iso)")?.insertion, "2026-06-30")
    }
    func testDateWeekdayNavigation() {
        XCTAssertEqual(fixedEngine().evaluate("next-fri(iso)")?.insertion, "2026-06-26")
        XCTAssertEqual(fixedEngine().evaluate("this-tue(iso)")?.insertion, "2026-06-23")
        XCTAssertEqual(fixedEngine().evaluate("last-tue(iso)")?.insertion, "2026-06-16")
        XCTAssertEqual(fixedEngine().evaluate("nextfri(iso)")?.insertion, "2026-06-26")
    }
    func testTime24Hour() {
        XCTAssertEqual(fixedEngine().evaluate("now(24h)")?.insertion, "14:30")
    }

    // Random (RNG returns the low bound by default)
    func testRandomFamilies() {
        XCTAssertEqual(fixedEngine().evaluate("dice")?.insertion, "1")
        XCTAssertEqual(fixedEngine().evaluate("d20")?.insertion, "1")
        XCTAssertEqual(fixedEngine().evaluate("coin")?.insertion, "Heads")
        XCTAssertEqual(fixedEngine().evaluate("random(5,10)")?.insertion, "5")
        XCTAssertEqual(fixedEngine().evaluate("uuid")?.insertion, "FIXED-UUID")
    }
    func testDiceHighBound() {
        XCTAssertEqual(fixedEngine(random: { $0.upperBound }).evaluate("d20")?.insertion, "20")
    }

    // Unit conversion
    func testUnitConversions() {
        XCTAssertEqual(fixedEngine().evaluate("10km->mi")?.insertion, "6.214 mi")
        XCTAssertEqual(fixedEngine().evaluate("1000m->km")?.insertion, "1 km")
        XCTAssertEqual(fixedEngine().evaluate("10 km to mi")?.insertion, "6.214 mi")
    }
    func testCrossQuantityIsNotConverted() {
        XCTAssertNil(fixedEngine().evaluate("10km->kg"))
    }

    // Currency (bundled offline rates: USD=1.0, EUR=0.92)
    func testCurrencyConversion() {
        XCTAssertTrue(fixedEngine().evaluate("100usd to eur")?.insertion.contains("92") ?? false)
        XCTAssertTrue(fixedEngine().evaluate("$100 to eur")?.insertion.contains("92") ?? false)
    }
    func testAmbiguousCurrencyReturnsNil() {
        XCTAssertNil(fixedEngine().evaluate("100 kr to usd"))
    }

    // Trigger scan (boundary + internal slash + evaluate-gating)
    func testTrailingQueryScan() {
        XCTAssertEqual(CotypingMacro.trailingQuery(in: "go /today"), "today")
        XCTAssertEqual(CotypingMacro.trailingQuery(in: "/5+5"), "5+5")
        XCTAssertEqual(CotypingMacro.trailingQuery(in: "/5/2"), "5/2")
        XCTAssertNil(CotypingMacro.trailingQuery(in: "and/or"))
        XCTAssertNil(CotypingMacro.trailingQuery(in: "http://x"))
        XCTAssertNil(CotypingMacro.trailingQuery(in: "no slash"))
    }
    func testTrailingTokenLength() {
        XCTAssertEqual(CotypingMacro.trailingTokenLength(in: "go /today"), 6)
        XCTAssertEqual(CotypingMacro.trailingTokenLength(in: "/5+5"), 4)
    }
    func testMatchGatesOnEvaluation() {
        let hit = CotypingMacro.match(trailing: "/5/2")
        XCTAssertEqual(hit?.result.insertion, "2.5")
        XCTAssertEqual(hit?.tokenLength, 4)
        XCTAssertNil(CotypingMacro.match(trailing: "/notamacro"))
    }

    func testMacroSettingDefaultsOn() {
        XCTAssertTrue(AppSettings().cotypingMacros)
    }
}

// MARK: - Per-domain disable

final class CotypingBrowserDomainTests: XCTestCase {
    func testHostStripsWWWAndPath() {
        XCTAssertEqual(CotypingBrowserDomain.host(fromURLString: "https://www.bank.com/login?x=1"), "bank.com")
    }
    func testHostKeepsSubdomainAndLowercases() {
        XCTAssertEqual(CotypingBrowserDomain.host(fromURLString: "https://Mail.Bank.com"), "mail.bank.com")
    }
    func testHostNilForNonWebURLs() {
        XCTAssertNil(CotypingBrowserDomain.host(fromURLString: "file:///Users/x"))
        XCTAssertNil(CotypingBrowserDomain.host(fromURLString: "about:blank"))
        XCTAssertNil(CotypingBrowserDomain.host(fromURLString: ""))
    }

    func testExactAndSubdomainMatch() {
        XCTAssertTrue(CotypingBrowserDomain.isHostDisabled("bank.com", excludedDomains: ["bank.com"]))
        XCTAssertTrue(CotypingBrowserDomain.isHostDisabled("mail.bank.com", excludedDomains: ["bank.com"]))
    }
    func testListEntryToleratesWWWAndFullURL() {
        XCTAssertTrue(CotypingBrowserDomain.isHostDisabled("bank.com", excludedDomains: ["www.bank.com"]))
        XCTAssertTrue(CotypingBrowserDomain.isHostDisabled("bank.com", excludedDomains: ["https://bank.com/login"]))
    }
    func testSuffixLookalikeIsNotMatched() {
        XCTAssertFalse(CotypingBrowserDomain.isHostDisabled("evilbank.com", excludedDomains: ["bank.com"]))
        XCTAssertFalse(CotypingBrowserDomain.isHostDisabled("notbank.com", excludedDomains: ["bank.com"]))
    }
    func testEmptyHostOrListNeverMatches() {
        XCTAssertFalse(CotypingBrowserDomain.isHostDisabled(nil, excludedDomains: ["bank.com"]))
        XCTAssertFalse(CotypingBrowserDomain.isHostDisabled("bank.com", excludedDomains: []))
    }
}

final class CotypingDomainGateTests: XCTestCase {
    private func supportedFocus(host: String?) -> CotypingFocus {
        let field = CotypingField(
            appName: "Safari", bundleID: "com.apple.Safari", processID: 1, role: "AXTextArea",
            precedingText: "hello", trailingText: "", selectionLength: 0, caretRect: .zero,
            isSecure: false, caretIsExact: true)
        return CotypingFocus(appName: "Safari", bundleID: "com.apple.Safari",
                             capability: .supported, field: field, host: host)
    }

    func testDisabledOnExcludedDomain() {
        let reason = CotypingAvailability.disabledReason(
            enabled: true, excludedApps: [], excludedDomains: ["bank.com"],
            selfBundleID: nil, focus: supportedFocus(host: "bank.com"))
        XCTAssertEqual(reason, "Disabled on bank.com.")
    }
    func testAllowedOffExcludedDomain() {
        XCTAssertNil(CotypingAvailability.disabledReason(
            enabled: true, excludedApps: [], excludedDomains: ["bank.com"],
            selfBundleID: nil, focus: supportedFocus(host: "github.com")))
    }
    func testNoDomainRulesAllowsBrowser() {
        XCTAssertNil(CotypingAvailability.disabledReason(
            enabled: true, excludedApps: [], excludedDomains: [],
            selfBundleID: nil, focus: supportedFocus(host: "bank.com")))
    }
    func testNilHostNeverGated() {
        XCTAssertNil(CotypingAvailability.disabledReason(
            enabled: true, excludedApps: [], excludedDomains: ["bank.com"],
            selfBundleID: nil, focus: supportedFocus(host: nil)))
    }

    func testExcludedDomainListParse() {
        XCTAssertTrue(AppSettings().cotypingExcludedDomains.isEmpty)
        var settings = AppSettings()
        settings.cotypingExcludedDomains = "bank.com, https://x.com/y ,"
        XCTAssertEqual(settings.cotypingExcludedDomainList, ["bank.com", "https://x.com/y"])
    }
}

// MARK: - Ghost styling (host font/color match)

final class CotypingFieldStyleTests: XCTestCase {
    func testIsEmpty() {
        XCTAssertTrue(CotypingFieldStyle().isEmpty)
        XCTAssertFalse(CotypingFieldStyle(fontName: "Helvetica").isEmpty)
        XCTAssertFalse(CotypingFieldStyle(colorHex: "336699").isEmpty)
        XCTAssertFalse(CotypingFieldStyle(backgroundColorHex: "000000").isEmpty)
    }

    func testHexRoundTrip() {
        let color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let hex = CotypingTextColorCodec.hexString(from: color)
        XCTAssertEqual(hex, "336699")
        let back = CotypingTextColorCodec.nsColor(fromHex: hex)
        XCTAssertEqual(back?.redComponent ?? 0, 51.0 / 255, accuracy: 0.001)
        XCTAssertEqual(back?.greenComponent ?? 0, 102.0 / 255, accuracy: 0.001)
        XCTAssertEqual(back?.blueComponent ?? 0, 153.0 / 255, accuracy: 0.001)
    }

    func testHexParseRejectsInvalid() {
        XCTAssertNil(CotypingTextColorCodec.nsColor(fromHex: nil))
        XCTAssertNil(CotypingTextColorCodec.nsColor(fromHex: "xyz"))
        XCTAssertNil(CotypingTextColorCodec.nsColor(fromHex: "12345"))   // 5 digits
        XCTAssertNil(CotypingTextColorCodec.nsColor(fromHex: "GGGGGG"))
        XCTAssertNotNil(CotypingTextColorCodec.nsColor(fromHex: "FFFFFF"))
    }

    func testClampedPointSize() {
        XCTAssertEqual(CotypingGhostStyle.clampedPointSize(nil), 13)
        XCTAssertEqual(CotypingGhostStyle.clampedPointSize(8), 9)      // below floor
        XCTAssertEqual(CotypingGhostStyle.clampedPointSize(50), 28)    // above ceiling
        XCTAssertEqual(CotypingGhostStyle.clampedPointSize(16), 16)    // in range
    }

    func testFontFromStyleClampsSize() {
        // "Helvetica" is always present on macOS.
        let font = CotypingGhostStyle.font(from: CotypingFieldStyle(fontName: "Helvetica", fontPointSize: 50))
        XCTAssertEqual(font?.pointSize, 28)
        XCTAssertEqual(font?.fontName, "Helvetica")
    }

    func testFontNilForUnknownNameOrNoStyle() {
        XCTAssertNil(CotypingGhostStyle.font(from: nil))
        XCTAssertNil(CotypingGhostStyle.font(from: CotypingFieldStyle(fontName: "Definitely-Not-A-Font")))
    }

    func testMeasuredTextSizeCoversLeadingSpaceSuggestion() {
        let size = CotypingGhostStyle.measuredTextSize(
            " up on this",
            style: CotypingFieldStyle(fontName: "Helvetica", fontPointSize: 12))

        XCTAssertGreaterThan(size.width, 20)
        XCTAssertGreaterThan(size.height, 8)
    }

    func testGhostColorDimsHostColor() {
        let color = CotypingGhostStyle.ghostColor(from: CotypingFieldStyle(colorHex: "336699"))
        XCTAssertEqual(color?.alphaComponent ?? 0, CotypingGhostStyle.ghostOpacity, accuracy: 0.001)
        XCTAssertEqual(color?.redComponent ?? 0, 51.0 / 255, accuracy: 0.001)
    }

    func testGhostColorNilWithoutHex() {
        XCTAssertNil(CotypingGhostStyle.ghostColor(from: nil))
        XCTAssertNil(CotypingGhostStyle.ghostColor(from: CotypingFieldStyle(fontName: "Helvetica")))
    }

    func testMatchHostStyleDefaultsOn() {
        XCTAssertTrue(AppSettings().cotypingMatchHostStyle)
    }

    func testResolvedGhostColorDimsReadableForeground() {
        let style = CotypingFieldStyle(colorHex: "FFFFFF", backgroundColorHex: "000000")
        let color = CotypingGhostStyle.resolvedGhostColor(from: style, isDarkEnvironment: false)
        XCTAssertEqual(color.alphaComponent, CotypingGhostStyle.ghostOpacity, accuracy: 0.001)
        XCTAssertGreaterThan(CotypingGhostStyle.relativeLuminance(of: color), 0.9) // stays white
    }

    func testResolvedGhostColorUsesBackgroundWhenNoForeground() {
        let onDark = CotypingGhostStyle.resolvedGhostColor(
            from: CotypingFieldStyle(backgroundColorHex: "1E1E1E"), isDarkEnvironment: false)
        XCTAssertGreaterThan(CotypingGhostStyle.relativeLuminance(of: onDark), 0.9)  // light hint
        let onLight = CotypingGhostStyle.resolvedGhostColor(
            from: CotypingFieldStyle(backgroundColorHex: "FFFFFF"), isDarkEnvironment: true)
        XCTAssertLessThan(CotypingGhostStyle.relativeLuminance(of: onLight), 0.1)    // dark hint
    }

    func testResolvedGhostColorFallsBackToEnvironmentWithoutHostColors() {
        let dark = CotypingGhostStyle.resolvedGhostColor(from: nil, isDarkEnvironment: true)
        let light = CotypingGhostStyle.resolvedGhostColor(from: nil, isDarkEnvironment: false)
        XCTAssertGreaterThan(CotypingGhostStyle.relativeLuminance(of: dark), 0.9)
        XCTAssertLessThan(CotypingGhostStyle.relativeLuminance(of: light), 0.1)
    }

    func testResolvedGhostColorOverridesForegroundIndistinguishableFromBackground() {
        // A host fg flattened to the background color (wrong-appearance capture)
        // must not paint invisible text — synthesize a legible hint instead.
        let style = CotypingFieldStyle(colorHex: "000000", backgroundColorHex: "000000")
        let color = CotypingGhostStyle.resolvedGhostColor(from: style, isDarkEnvironment: false)
        XCTAssertGreaterThan(CotypingGhostStyle.relativeLuminance(of: color), 0.9) // light, not black
    }

    func testLuminanceAndContrastExtremes() {
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(CotypingGhostStyle.relativeLuminance(of: white), 1, accuracy: 0.001)
        XCTAssertEqual(CotypingGhostStyle.relativeLuminance(of: black), 0, accuracy: 0.001)
        XCTAssertGreaterThan(CotypingGhostStyle.contrastRatio(white, black), 20)
        XCTAssertEqual(CotypingGhostStyle.contrastRatio(white, white), 1, accuracy: 0.001)
    }

    func testMeasuredLuminanceDrivesGhostContrast() {
        let style = CotypingFieldStyle(colorHex: "111111")  // near-black host fg, no bg reported
        // Measured-dark background → flip to a light hint (the reported bug).
        let onDark = CotypingGhostStyle.resolvedGhostColor(
            from: style, isDarkEnvironment: false, measuredLuminance: 0.03)
        XCTAssertGreaterThan(CotypingGhostStyle.relativeLuminance(of: onDark), 0.9)
        // Measured-light background → keep the legible dark host color.
        let onLight = CotypingGhostStyle.resolvedGhostColor(
            from: style, isDarkEnvironment: true, measuredLuminance: 0.97)
        XCTAssertLessThan(CotypingGhostStyle.relativeLuminance(of: onLight), 0.2)
    }

    func testAverageLuminanceOfSolidImages() {
        XCTAssertGreaterThan(
            CotypingBackgroundSampler.averageLuminance(of: solidImage(white: 1)) ?? 0, 0.95)
        XCTAssertLessThan(
            CotypingBackgroundSampler.averageLuminance(of: solidImage(white: 0)) ?? 1, 0.05)
    }

    private func solidImage(white: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: white, green: white, blue: white, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return ctx.makeImage()!
    }
}

// MARK: - Mirror render mode

final class CotypingRenderModeTests: XCTestCase {
    func testIsCaretAtEndOfLine() {
        XCTAssertTrue(CotypingRenderModePolicy.isCaretAtEndOfLine(trailingText: ""))
        XCTAssertTrue(CotypingRenderModePolicy.isCaretAtEndOfLine(trailingText: "\nrest"))
        XCTAssertFalse(CotypingRenderModePolicy.isCaretAtEndOfLine(trailingText: "world"))
        XCTAssertFalse(CotypingRenderModePolicy.isCaretAtEndOfLine(trailingText: " \n"))  // leading space = mid-line
    }

    func testAutoExactEndOfLineIsInline() {
        let mode = CotypingRenderModePolicy(userPreference: .auto).mode(caretIsExact: true, isCaretAtEndOfLine: true)
        XCTAssertEqual(mode, .inline)
    }

    func testAutoExactMidLinePromotesToMirror() {
        let mode = CotypingRenderModePolicy(userPreference: .auto).mode(caretIsExact: true, isCaretAtEndOfLine: false)
        XCTAssertEqual(mode, .mirror(reason: .caretMidLine))
    }

    func testAutoEstimatedEndOfLineUsesMirror() {
        let endOfLine = CotypingRenderModePolicy(userPreference: .auto).mode(caretIsExact: false, isCaretAtEndOfLine: true)
        let midLine = CotypingRenderModePolicy(userPreference: .auto).mode(caretIsExact: false, isCaretAtEndOfLine: false)
        XCTAssertEqual(endOfLine, .mirror(reason: .caretGeometryEstimated))
        XCTAssertEqual(midLine, .mirror(reason: .caretMidLine))
    }

    func testAlwaysInlineMidLineStillOverrides() {
        // An explicit inline pin cannot render mid-line, so it is promoted too.
        let mode = CotypingRenderModePolicy(userPreference: .alwaysInline).mode(caretIsExact: true, isCaretAtEndOfLine: false)
        XCTAssertEqual(mode, .mirror(reason: .caretMidLine))
    }

    func testAlwaysInlineEndOfLineIsInline() {
        let mode = CotypingRenderModePolicy(userPreference: .alwaysInline).mode(caretIsExact: true, isCaretAtEndOfLine: true)
        XCTAssertEqual(mode, .inline)
    }

    func testAlwaysMirrorReasonIsUserPreference() {
        let mode = CotypingRenderModePolicy(userPreference: .alwaysMirror).mode(caretIsExact: true, isCaretAtEndOfLine: true)
        XCTAssertEqual(mode, .mirror(reason: .userPreference))
    }

    func testPlacementComposesIntoMode() {
        let inline = CotypingOverlayPlacement(caretIsExact: true, isCaretAtEndOfLine: true, preference: .auto)
        let estimatedEnd = CotypingOverlayPlacement(caretIsExact: false, isCaretAtEndOfLine: true, preference: .auto)
        XCTAssertEqual(inline.mode, .inline)
        XCTAssertEqual(estimatedEnd.mode, .mirror(reason: .caretGeometryEstimated))
    }

    func testPreferenceDefaultsToAuto() {
        XCTAssertEqual(AppSettings().cotypingMirrorPreference, .auto)
    }
}

// MARK: - Quality metrics

final class CotypingStatsTests: XCTestCase {
    func testDefaults() {
        let stats = CotypingStats()
        XCTAssertEqual(stats.generations, 0)
        XCTAssertEqual(stats.accepts, 0)
        XCTAssertEqual(stats.charsAccepted, 0)
        XCTAssertEqual(stats.latenciesMs, [])
        XCTAssertNil(stats.avgLatencyMs)
        XCTAssertNil(stats.p95LatencyMs)
        XCTAssertEqual(stats.acceptsPerGeneration, 0)
    }

    func testRecordGenerationAndAccept() {
        var stats = CotypingStats()
        stats.recordGeneration(latencyMs: 100)
        stats.recordGeneration(latencyMs: 200)
        stats.recordAccept(charsAccepted: 12)
        XCTAssertEqual(stats.generations, 2)
        XCTAssertEqual(stats.accepts, 1)
        XCTAssertEqual(stats.charsAccepted, 12)
        XCTAssertEqual(stats.acceptsPerGeneration, 0.5, accuracy: 0.001)
    }

    func testLatencyCap() {
        var stats = CotypingStats()
        for ms in 1...55 { stats.recordGeneration(latencyMs: ms) }
        XCTAssertEqual(stats.latenciesMs.count, CotypingStats.maxLatencies)  // 50
        XCTAssertEqual(stats.latenciesMs.first, 6)  // first five dropped
        XCTAssertEqual(stats.latenciesMs.last, 55)
    }

    func testDerivedLatencyStats() {
        var stats = CotypingStats()
        [100, 200, 300, 400, 500].forEach { stats.recordGeneration(latencyMs: $0) }
        XCTAssertEqual(stats.avgLatencyMs, 300)
        XCTAssertEqual(stats.medianLatencyMs, 300)
        XCTAssertEqual(stats.p95LatencyMs, 500)   // idx = round(4*0.95) = 4
        XCTAssertEqual(stats.maxLatencyMs, 500)
    }

    func testSingleSampleLatency() {
        var stats = CotypingStats()
        stats.recordGeneration(latencyMs: 150)
        XCTAssertEqual(stats.avgLatencyMs, 150)
        XCTAssertEqual(stats.medianLatencyMs, 150)
        XCTAssertEqual(stats.p95LatencyMs, 150)
        XCTAssertEqual(stats.maxLatencyMs, 150)
    }

    func testReset() {
        var stats = CotypingStats()
        stats.recordGeneration(latencyMs: 100)
        stats.recordError()
        stats.reset()
        XCTAssertEqual(stats, CotypingStats())
    }

    func testCodableRoundTrip() {
        var stats = CotypingStats()
        stats.recordGeneration(latencyMs: 120)
        stats.recordGeneration(latencyMs: 340)
        stats.recordAccept(charsAccepted: 9)
        stats.recordError()
        let data = try! JSONEncoder().encode(stats)
        let decoded = try! JSONDecoder().decode(CotypingStats.self, from: data)
        XCTAssertEqual(decoded, stats)
    }
}

final class CotypingStatsStoreTests: XCTestCase {
    @MainActor
    func testPersistAndReload() {
        let name = "cotyping-stats-test"
        UserDefaults().removePersistentDomain(forName: name)
        let suite = UserDefaults(suiteName: name)!

        let store = CotypingStatsStore(defaults: suite)
        XCTAssertEqual(store.stats, CotypingStats())

        store.recordGeneration(latencyMs: 120)
        store.recordAccept(charsAccepted: 7)
        store.recordError()

        // A fresh store loading the same suite sees the persisted values.
        let reloaded = CotypingStatsStore(defaults: suite)
        XCTAssertEqual(reloaded.stats.generations, 1)
        XCTAssertEqual(reloaded.stats.accepts, 1)
        XCTAssertEqual(reloaded.stats.charsAccepted, 7)
        XCTAssertEqual(reloaded.stats.errors, 1)

        reloaded.clear()
        XCTAssertEqual(CotypingStatsStore(defaults: suite).stats, CotypingStats())

        suite.removePersistentDomain(forName: name)
    }
}

// MARK: - Clipboard context

final class CotypingClipboardContextTests: XCTestCase {
    func testSanitizeCollapsesAndTrims() {
        XCTAssertEqual(CotypingClipboardContext.sanitize("  hello   world  "), "hello world")
        XCTAssertEqual(CotypingClipboardContext.sanitize("a\n\nb\tc"), "a\nb c")
        XCTAssertEqual(CotypingClipboardContext.sanitize("hello"), "hello")
    }

    func testSanitizeStripsAnsiEscapesAndPromptShapedPunctuation() {
        let input = "\u{001B}[31mraw-output\u{001B}[0m ```$ deploy --prod```"

        XCTAssertEqual(CotypingClipboardContext.sanitize(input), "raw output deploy prod")
    }

    func testSanitizeDropsEmpty() {
        XCTAssertNil(CotypingClipboardContext.sanitize(nil))
        XCTAssertNil(CotypingClipboardContext.sanitize(""))
        XCTAssertNil(CotypingClipboardContext.sanitize("   \n\t  "))
        XCTAssertNil(CotypingClipboardContext.sanitize("*** --- ```"))
    }

    func testSanitizeCapsLength() {
        let long = String(repeating: "x", count: 2000)
        let capped = CotypingClipboardContext.sanitize(long)
        XCTAssertEqual(capped?.count, CotypingClipboardContext.maxSnippetCharacters)
    }

    func testShouldIncludeGuardsAlreadyInField() {
        XCTAssertFalse(CotypingClipboardContext.shouldInclude(snippet: "abc", precedingText: "x abc y"))
        XCTAssertTrue(CotypingClipboardContext.shouldInclude(snippet: "abc", precedingText: "hello"))
        XCTAssertTrue(CotypingClipboardContext.shouldInclude(snippet: "abc", precedingText: ""))
        XCTAssertFalse(CotypingClipboardContext.shouldInclude(snippet: nil, precedingText: "hi"))
        XCTAssertFalse(CotypingClipboardContext.shouldInclude(snippet: "", precedingText: "hi"))
        XCTAssertFalse(CotypingClipboardContext.shouldInclude(
            snippet: "raw output",
            precedingText: "The raw-output log is attached"))
    }

    func testResolveCombinesSanitizeAndGuard() {
        XCTAssertEqual(CotypingClipboardContext.resolve(rawClipboard: "plans", precedingText: "meeting about"), "plans")
        XCTAssertNil(CotypingClipboardContext.resolve(rawClipboard: "plans", precedingText: "the plans are set"))  // already there
        XCTAssertNil(CotypingClipboardContext.resolve(rawClipboard: "   ", precedingText: "x"))                    // empty after sanitize
    }

    func testResolveDistillsLongClipboardToLinesOverlappingThePrefix() {
        let raw = """
        invoice totals and renewal schedule
        unrelated terminal output
        api rollout notes
        renewal customer summary
        """

        let result = CotypingClipboardContext.resolve(
            rawClipboard: raw,
            precedingText: "I will send the renewal update")

        XCTAssertEqual(result, "invoice totals and renewal schedule\nrenewal customer summary")
    }

    func testPromptIncludesClipboardLine() {
        let prompt = CotypingPromptRenderer.prompt(prefixText: "hello", clipboardContext: "secret plans")
        XCTAssertTrue(prompt.contains("On the clipboard: secret plans"))
        XCTAssertTrue(prompt.contains("hello"))  // prefix still present
    }

    func testPromptOmitsClipboardWhenAbsent() {
        let prompt = CotypingPromptRenderer.prompt(prefixText: "hello")
        XCTAssertFalse(prompt.contains("On the clipboard"))
    }

    func testPromptCapsClipboardLine() {
        let huge = String(repeating: "z", count: 600)
        let prompt = CotypingPromptRenderer.prompt(prefixText: "hi", clipboardContext: huge)
        // The clipboard line itself is capped at maxClipboardLineCharacters.
        let line = prompt.components(separatedBy: "\n").first(where: { $0.contains("On the clipboard") }) ?? ""
        XCTAssertLessThanOrEqual(line.count, "On the clipboard: ".count + CotypingPromptRenderer.maxClipboardLineCharacters)
    }

    func testUseClipboardDefaultsOff() {
        XCTAssertFalse(AppSettings().cotypingUseClipboard)
    }

    func testClipboardSignificantTokensIgnoreShortTokensAndCase() {
        XCTAssertEqual(
            CotypingClipboardContext.significantTokens(from: "A deployment, API, and x y z"),
            ["deployment", "api", "and"])
    }

    func testClipboardRelevanceFirstObservationBaselinesWithoutInjecting() {
        let filter = CotypingClipboardRelevanceFilter()

        XCTAssertNil(filter.filter(
            rawClipboard: "meeting agenda",
            pasteboardChangeCount: 42,
            precedingText: "the meeting starts soon"))
    }

    func testClipboardRelevanceFreshCopyRequiresTokenOverlap() {
        let filter = CotypingClipboardRelevanceFilter()
        _ = filter.filter(
            rawClipboard: "baseline content",
            pasteboardChangeCount: 1,
            precedingText: "")

        XCTAssertNil(filter.filter(
            rawClipboard: "SELECT * FROM users",
            pasteboardChangeCount: 2,
            precedingText: "Dear hiring manager"))
        XCTAssertEqual(filter.filter(
            rawClipboard: "Deployment Pipeline",
            pasteboardChangeCount: 3,
            precedingText: "the deployment is running"),
            "Deployment Pipeline")
    }

    func testClipboardRelevanceIgnoresShortTokenOverlap() {
        let filter = CotypingClipboardRelevanceFilter()
        _ = filter.filter(
            rawClipboard: "baseline content",
            pasteboardChangeCount: 1,
            precedingText: "")

        XCTAssertNil(filter.filter(
            rawClipboard: "a b c",
            pasteboardChangeCount: 2,
            precedingText: "a b c d e"))
    }

    func testClipboardRelevanceExpiresAndNewCopyResetsClock() {
        var now = Date()
        let filter = CotypingClipboardRelevanceFilter(dateProvider: { now })
        _ = filter.filter(
            rawClipboard: "baseline content",
            pasteboardChangeCount: 1,
            precedingText: "")

        XCTAssertEqual(filter.filter(
            rawClipboard: "first content",
            pasteboardChangeCount: 2,
            precedingText: "first content"),
            "first content")

        now = now.addingTimeInterval(CotypingClipboardRelevanceFilter.staleThresholdSeconds + 1)

        XCTAssertNil(filter.filter(
            rawClipboard: "first content",
            pasteboardChangeCount: 2,
            precedingText: "first content"))
        XCTAssertEqual(filter.filter(
            rawClipboard: "second content",
            pasteboardChangeCount: 3,
            precedingText: "second content"),
            "second content")
    }

    func testClipboardPrefaceMemoReusesOnlySameFieldAndChangeCount() {
        let memo = CotypingClipboardPrefaceMemo(
            identityKey: "field-a",
            changeCount: 12,
            value: "release notes")

        XCTAssertEqual(
            memo.valueIfReusable(identityKey: "field-a", changeCount: 12),
            "release notes")
        XCTAssertNil(memo.valueIfReusable(identityKey: "field-b", changeCount: 12))
        XCTAssertNil(memo.valueIfReusable(identityKey: "field-a", changeCount: 13))
    }
}

// MARK: - Insertion strategy (keystroke vs paste)

final class CotypingInsertionStrategyTests: XCTestCase {
    func testDisabledAlwaysKeystroke() {
        XCTAssertEqual(CotypingInsertionStrategySelector.select(forChunk: "line one\nline two", pasteEnabled: false), .keystroke)
        XCTAssertEqual(CotypingInsertionStrategySelector.select(forChunk: String(repeating: "x", count: 200), pasteEnabled: false), .keystroke)
    }

    func testMultilinePastes() {
        XCTAssertEqual(CotypingInsertionStrategySelector.select(forChunk: "a\nb", pasteEnabled: true), .paste)
    }

    func testLongPastes() {
        XCTAssertEqual(CotypingInsertionStrategySelector.select(forChunk: String(repeating: "x", count: 80), pasteEnabled: true), .paste)
        XCTAssertEqual(CotypingInsertionStrategySelector.select(forChunk: String(repeating: "x", count: 200), pasteEnabled: true), .paste)
    }

    func testShortSingleLineKeystrokes() {
        XCTAssertEqual(CotypingInsertionStrategySelector.select(forChunk: "hello world", pasteEnabled: true), .keystroke)
        XCTAssertEqual(CotypingInsertionStrategySelector.select(forChunk: String(repeating: "x", count: 79), pasteEnabled: true), .keystroke)
    }

    func testComposingIMEAlwaysPastes() {
        XCTAssertEqual(
            CotypingInsertionStrategySelector.select(
                forChunk: "short",
                pasteEnabled: false,
                isComposingIMEActive: true),
            .paste)
    }

    func testPasteInsertionDefaultsOn() {
        XCTAssertTrue(AppSettings().cotypingPasteInsertion)
    }
}

// MARK: - IME composition input modes

final class CotypingCompositionInputModeClassifierTests: XCTestCase {
    func testPlainKeyboardLayoutIsNotComposing() {
        XCTAssertFalse(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: true,
                inputModeID: nil))
    }

    func testKnownComposingModesAreComposing() {
        XCTAssertTrue(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.Japanese.Hiragana"))
        XCTAssertTrue(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.SCIM.ITABC"))
        XCTAssertTrue(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.Korean.2SetKorean"))
    }

    func testRomanDirectModeIsNotComposing() {
        XCTAssertFalse(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.Roman"))
    }

    func testUnknownNonLayoutInputMethodIsComposing() {
        XCTAssertTrue(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: nil))
        XCTAssertTrue(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.justsystems.inputmethod.atok33.Japanese"))
    }
}

// MARK: - Overlay geometry

final class CotypingSuggestionFadeInPolicyTests: XCTestCase {
    func testFadesOnlyOnFreshAppearanceWhenEnabledAndMotionAllowed() {
        XCTAssertTrue(CotypingSuggestionFadeInPolicy.shouldFadeIn(
            isEnabled: true,
            overlayWasVisible: false,
            reduceMotionEnabled: false))
        XCTAssertFalse(CotypingSuggestionFadeInPolicy.shouldFadeIn(
            isEnabled: true,
            overlayWasVisible: true,
            reduceMotionEnabled: false))
    }

    func testDisabledAndReduceMotionBothSuppressFade() {
        XCTAssertFalse(CotypingSuggestionFadeInPolicy.shouldFadeIn(
            isEnabled: false,
            overlayWasVisible: false,
            reduceMotionEnabled: false))
        XCTAssertFalse(CotypingSuggestionFadeInPolicy.shouldFadeIn(
            isEnabled: true,
            overlayWasVisible: false,
            reduceMotionEnabled: true))
    }

    func testFadeDurationClampUsesCotypistBand() {
        XCTAssertEqual(
            CotypingSuggestionFadeInPolicy.clampedDurationSeconds(0.001),
            CotypingSuggestionFadeInPolicy.minimumDurationSeconds,
            accuracy: 0.0001)
        XCTAssertEqual(
            CotypingSuggestionFadeInPolicy.clampedDurationSeconds(2),
            CotypingSuggestionFadeInPolicy.maximumDurationSeconds,
            accuracy: 0.0001)
        XCTAssertEqual(
            CotypingSuggestionFadeInPolicy.clampedDurationSeconds(.infinity),
            CotypingSuggestionFadeInPolicy.defaultDurationSeconds,
            accuracy: 0.0001)
    }
}

final class CotypingGhostHighlightTests: XCTestCase {
    func testHighlightsNextAcceptedLatinChunk() {
        XCTAssertEqual(CotypingGhostHighlight.acceptancePrefix(in: "hello world"), "hello ")
        XCTAssertEqual(CotypingGhostHighlight.acceptancePrefix(in: "done\nnext"), "done")
    }

    func testHighlightsNextAcceptedSpacelessScriptChunk() {
        let run = "\u{4f60}\u{597d}\u{4e16}\u{754c}"
        let prefix = CotypingGhostHighlight.acceptancePrefix(in: run)
        XCTAssertFalse(prefix.isEmpty)
        XCTAssertTrue(run.hasPrefix(prefix))
        XCTAssertLessThan(prefix.count, run.count)
    }

    func testHighlightsBoundCJKPunctuationChunk() {
        XCTAssertEqual(
            CotypingGhostHighlight.acceptancePrefix(in: "\u{8cc7}\u{6599}\u{3001}\u{5185}\u{5bb9}"),
            "\u{8cc7}\u{6599}\u{3001}")
    }
}

final class CotypingOverlayGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testAcceptanceHintAddsKeycapWidthToOverlayBudget() {
        let textSize = CGSize(width: 72, height: 16)
        let hinted = CotypingAcceptanceHintLayout.reservedSize(for: textSize, label: "Tab")

        XCTAssertGreaterThan(hinted.width, textSize.width + CotypingAcceptanceHintLayout.spacing)
        XCTAssertGreaterThanOrEqual(hinted.height, textSize.height)
        XCTAssertEqual(CotypingAcceptanceHintLayout.reservedSize(for: textSize, label: nil), textSize)
    }

    func testInlineFrameUsesAcceptanceHintBudget() {
        let baseTextSize = CGSize(width: 60, height: 16)
        let hintedTextSize = CotypingAcceptanceHintLayout.reservedSize(
            for: baseTextSize,
            label: "Right Arrow")
        let frame = CotypingOverlayGeometry.inlineFrame(
            caret: CGRect(x: 100, y: 500, width: 0, height: 16),
            textSize: hintedTextSize,
            lineHeight: 16,
            visible: screen)

        XCTAssertEqual(frame.width, hintedTextSize.width, accuracy: 0.5)
        XCTAssertGreaterThan(frame.width, baseTextSize.width)
    }

    /// The core consistency property: two AX providers reporting the same line
    /// center with different caret heights (AppKit line box vs WebKit marker
    /// bounds) must place the ghost at the identical vertical center and height.
    func testInlineCentersOnCaretRegardlessOfCaretHeight() {
        let shortCaret = CotypingOverlayGeometry.inlineFrame(
            caret: CGRect(x: 100, y: 500, width: 0, height: 14),   // midY 507
            textSize: CGSize(width: 60, height: 16), lineHeight: 16, visible: screen)
        let tallCaret = CotypingOverlayGeometry.inlineFrame(
            caret: CGRect(x: 100, y: 497, width: 0, height: 20),   // midY 507
            textSize: CGSize(width: 60, height: 16), lineHeight: 16, visible: screen)
        XCTAssertEqual(shortCaret.midY, 507, accuracy: 0.5)
        XCTAssertEqual(tallCaret.midY, 507, accuracy: 0.5)
        XCTAssertEqual(shortCaret.height, tallCaret.height)
    }

    func testInlineAnchorsRightOfCaretWithGap() {
        let frame = CotypingOverlayGeometry.inlineFrame(
            caret: CGRect(x: 100, y: 500, width: 0, height: 16),
            textSize: CGSize(width: 60, height: 16), lineHeight: 16, visible: screen)
        XCTAssertEqual(frame.minX, 102)
        XCTAssertEqual(frame.width, 60)
    }

    func testAdvancedInlineFrameSlidesByAcceptedTextWidth() throws {
        let frame = CotypingOverlayGeometry.inlineFrame(
            caret: CGRect(x: 100, y: 500, width: 0, height: 16),
            textSize: CGSize(width: 160, height: 16), lineHeight: 16, visible: screen)
        let advanced = try XCTUnwrap(CotypingOverlayGeometry.advancedInlineFrame(
            from: frame,
            insertedTextSize: CGSize(width: 42, height: 16),
            remainingTextSize: CGSize(width: 118, height: 16),
            lineHeight: 16,
            visible: screen))

        XCTAssertEqual(advanced.minX, frame.minX + 42, accuracy: 0.5)
        XCTAssertEqual(advanced.midY, frame.midY, accuracy: 0.5)
        XCTAssertEqual(advanced.width, 118)
    }

    func testAdvancedInlineFrameFallsBackWhenSlideWouldOverflow() {
        let frame = CGRect(x: 1340, y: 500, width: 90, height: 16)
        let advanced = CotypingOverlayGeometry.advancedInlineFrame(
            from: frame,
            insertedTextSize: CGSize(width: 50, height: 16),
            remainingTextSize: CGSize(width: 70, height: 16),
            lineHeight: 16,
            visible: screen)

        XCTAssertNil(advanced)
    }

    func testInlineReanchorHoldsSmallSameTextDrift() {
        XCTAssertTrue(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 124, y: 497, width: 100, height: 16),
            millisecondsSinceLastAcceptance: nil))
    }

    func testInlineReanchorHoldsBackwardJumpInsidePostAcceptWindow() {
        XCTAssertTrue(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 160, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            millisecondsSinceLastAcceptance: 80))
    }

    func testInlineReanchorAllowsBackwardJumpAfterHoldWindow() {
        XCTAssertFalse(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 160, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            millisecondsSinceLastAcceptance: 450))
    }

    func testInlineReanchorAllowsForwardAndVerticalMoves() {
        XCTAssertFalse(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 140, y: 500, width: 100, height: 16),
            millisecondsSinceLastAcceptance: 80))
        XCTAssertFalse(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 120, y: 512, width: 100, height: 16),
            millisecondsSinceLastAcceptance: 80))
    }

    func testInlineClampsToRightEdgeInsteadOfOverflowing() {
        let frame = CotypingOverlayGeometry.inlineFrame(
            caret: CGRect(x: 1400, y: 500, width: 0, height: 16),
            textSize: CGSize(width: 200, height: 16), lineHeight: 16, visible: screen)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
    }

    func testInlineUsesLineHeightFloorWhenTextHeightUnreliable() {
        let frame = CotypingOverlayGeometry.inlineFrame(
            caret: CGRect(x: 10, y: 500, width: 0, height: 40),
            textSize: CGSize(width: 60, height: 0), lineHeight: 18, visible: nil)
        XCTAssertEqual(frame.height, 18)
    }

    func testMirrorSitsBelowCaretAndFlipsAboveWhenNoRoom() {
        let below = CotypingOverlayGeometry.mirrorFrame(
            caret: CGRect(x: 100, y: 500, width: 0, height: 16),
            content: CGSize(width: 120, height: 24), visible: screen)
        XCTAssertEqual(below.maxY, 498, accuracy: 0.5)

        let nearBottom = CotypingOverlayGeometry.mirrorFrame(
            caret: CGRect(x: 100, y: 5, width: 0, height: 16),
            content: CGSize(width: 120, height: 24), visible: screen)
        XCTAssertGreaterThanOrEqual(nearBottom.minY, screen.minY)
    }

    func testMirrorLayoutWrapsLongSuggestionWithinBudget() {
        let font = NSFont.systemFont(ofSize: 13)
        let maxWidth: CGFloat = 140
        let lines = CotypingGhostTextLayout.wrappedLines(
            text: "Please confirm the renewal schedule before sending the customer update",
            font: font,
            maxWidth: maxWidth,
            maxLines: 4)

        XCTAssertGreaterThan(lines.count, 1)
        for line in lines {
            let width = (line as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(width, maxWidth + 0.5)
        }
    }

    func testMirrorLayoutPreservesExplicitLineBoundaries() {
        let font = NSFont.systemFont(ofSize: 13)
        let lines = CotypingGhostTextLayout.wrappedLines(
            text: "first line\nsecond line",
            font: font,
            maxWidth: 400,
            maxLines: 4)

        XCTAssertEqual(lines, ["first line", "second line"])
    }

    func testMirrorLayoutEllipsizesWhenRowsAreExhausted() {
        let font = NSFont.systemFont(ofSize: 13)
        let lines = CotypingGhostTextLayout.wrappedLines(
            text: "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda",
            font: font,
            maxWidth: 90,
            maxLines: 2)

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasSuffix("..."))
    }

    func testAXRectConversionUsesContainingScreenFrame() {
        let converted = CotypingAXHelper.cocoaRect(
            fromAX: CGRect(x: 1500, y: -100, width: 2, height: 20),
            displayBounds: CGRect(x: 1440, y: -200, width: 1920, height: 1080),
            screenFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))

        XCTAssertEqual(converted.origin.x, 1500)
        XCTAssertEqual(converted.origin.y, 960)
        XCTAssertEqual(converted.width, 2)
        XCTAssertEqual(converted.height, 20)
    }
}
