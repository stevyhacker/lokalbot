import XCTest
@testable import LokalBotV3

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
}

// MARK: - Text normalizer

final class CotypingTextNormalizerTests: XCTestCase {
    private func request(prefix: String, trailing: String = "", multiLine: Bool = false) -> CotypingRequest {
        CotypingRequest(
            prompt: CotypingPromptRenderer.prompt(prefixText: prefix),
            prefixText: prefix, trailingText: trailing, isMultiLine: multiLine,
            maxTokens: 24, temperature: 0.1, topP: 0.7, topK: 20, minP: 0.08,
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
        let request = try XCTUnwrap(CotypingRequestBuilder.build(
            field: field(preceding: "Hello there"), config: .standard,
            personalization: .none, generation: 7))
        XCTAssertEqual(request.prefixText, "Hello there")
        XCTAssertEqual(request.prompt, "Hello there")
        XCTAssertEqual(request.generation, 7)
        XCTAssertEqual(request.maxTokens, CotypingConfiguration.standard.maxResponseTokens)
        XCTAssertFalse(request.isMultiLine)
    }

    func testPersonalizationEntersPrompt() throws {
        let personalization = CotypingPersonalization(
            userName: "Sam", styleNote: nil, languageHint: nil, isMultiLine: true)
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
            enabled: true, excludedApps: [], selfBundleID: "com.dotenv.LokalBotV3",
            focus: focus(app: "LokalBotV3", bundle: "com.dotenv.LokalBotV3"))
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
            enabled: true, excludedApps: ["Terminal"], selfBundleID: "com.dotenv.LokalBotV3", focus: focus()))
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
        settings.cotypingAcceptWholeSuggestion = true
        settings.cotypingExcludedApps = "Terminal, 1Password"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(decoded.cotypingEnabled)
        XCTAssertEqual(decoded.cotypingUserName, "Ada")
        XCTAssertEqual(decoded.cotypingMaxWords, 12)
        XCTAssertTrue(decoded.cotypingMultiLine)
        XCTAssertEqual(decoded.cotypingDebounceMs, 500)
        XCTAssertTrue(decoded.cotypingAcceptWholeSuggestion)
        XCTAssertEqual(decoded.cotypingExcludedAppList, ["Terminal", "1Password"])
    }

    func testTolerantDecodeKeepsOtherDefaults() throws {
        let data = #"{"cotypingEnabled":true}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(settings.cotypingEnabled)
        XCTAssertEqual(settings.cotypingMaxWords, AppSettings().cotypingMaxWords)
        XCTAssertTrue(settings.menuBarOnly)
    }

    func testMaxResponseTokensFloorAndCap() {
        var settings = AppSettings()
        settings.cotypingMaxWords = 2
        XCTAssertEqual(settings.cotypingMaxResponseTokens, 8)   // floor
        settings.cotypingMaxWords = 8
        XCTAssertEqual(settings.cotypingMaxResponseTokens, 24)  // 8 * 3
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

    func testDifferentProcessIsNotContinuation() {
        XCTAssertFalse(CotypingCoordinator.isContinuation(of: session("I wanted to follow", pid: 5), liveField: field("I wanted to follow", pid: 99)))
    }

    func testNoLiveFieldIsNotContinuation() {
        XCTAssertFalse(CotypingCoordinator.isContinuation(of: session("I wanted to follow"), liveField: nil))
    }
}
