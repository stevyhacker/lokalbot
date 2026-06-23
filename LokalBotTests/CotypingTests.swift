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

// MARK: - App/window (surface) context

final class CotypingSurfaceContextTests: XCTestCase {
    func testClassifier() {
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.apple.mail"), .email)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.google.Chrome"), .browser)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.apple.dt.Xcode"), .codeEditor)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.apple.Terminal"), .terminal)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.acme.unknown"), .other)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: nil), .other)
    }

    func testSuppressedInCodeEditorAndTerminal() {
        XCTAssertNil(CotypingSurfaceComposer.compose(
            appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "main.swift", fieldPlaceholder: nil))
        XCTAssertNil(CotypingSurfaceComposer.compose(
            appName: "Terminal", bundleID: "com.apple.Terminal", windowTitle: "bash", fieldPlaceholder: nil))
    }

    func testGenericAppWithNoCuesIsNil() {
        XCTAssertNil(CotypingSurfaceComposer.compose(
            appName: "SomeApp", bundleID: "com.acme.app", windowTitle: nil, fieldPlaceholder: nil))
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
            " ord", for: request(prefix: "rec", trailing: "x", force: true))
        XCTAssertEqual(forced, "ord")
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
