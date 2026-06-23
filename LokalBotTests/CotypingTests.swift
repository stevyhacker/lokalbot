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
        settings.cotypingAcceptGranularity = .phrase
        settings.cotypingFullAcceptKey = .rightArrow
        settings.cotypingExcludedApps = "Terminal, 1Password"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(decoded.cotypingEnabled)
        XCTAssertEqual(decoded.cotypingUserName, "Ada")
        XCTAssertEqual(decoded.cotypingMaxWords, 12)
        XCTAssertTrue(decoded.cotypingMultiLine)
        XCTAssertEqual(decoded.cotypingDebounceMs, 500)
        XCTAssertEqual(decoded.cotypingAcceptGranularity, .phrase)
        XCTAssertEqual(decoded.cotypingFullAcceptKey, .rightArrow)
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

final class CotypingPhraseTests: XCTestCase {
    func testStopsAtClauseBoundary() {
        XCTAssertEqual(CotypingCoordinator.nextPhrase(in: "Hi Sarah, thanks"), "Hi Sarah, ")
    }
    func testWholeTextWhenNoBoundary() {
        XCTAssertEqual(CotypingCoordinator.nextPhrase(in: "the quick brown"), "the quick brown")
    }
    func testStopsAtSentenceEnd() {
        XCTAssertEqual(CotypingCoordinator.nextPhrase(in: "done. next thing"), "done. ")
    }
    func testCJKClauseBoundary() {
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

final class CotypingDebounceTests: XCTestCase {
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
