import Combine
import CoreGraphics
import Foundation

/// Orchestrates cotyping: focus polling → debounce → generation → ghost overlay
/// → accept-on-Tab. Trimmed port of Cotabby's `SuggestionCoordinator`, adapted
/// to LokalBot's HTTP completion engine. Owns the session and the work-id
/// (`generation`) that drops superseded results.
///
/// Started/stopped by `AppState` from the cotyping setting + permission state.
@MainActor
final class CotypingCoordinator: ObservableObject {
    /// Live status for the in-app Cotyping section.
    @Published private(set) var state: CotypingState = .idle
    /// True while the subsystem is running (taps + focus poll installed).
    @Published private(set) var isRunning = false
    /// Last non-empty suggestion shown (diagnostics).
    @Published private(set) var lastSuggestion: String?
    /// Words accepted this session (diagnostics).
    @Published private(set) var acceptedWordCount = 0

    private let focusTracker: CotypingFocusTracker
    private let inputMonitor: CotypingInputMonitor
    private let inputSourceMonitor: CotypingKeyboardInputSourceMonitor
    private let overlay: CotypingOverlayController
    private let inserter: CotypingInserter
    private let engine: CotypingCompleting
    private let learningStore: CotypingLearningStore
    private let settingsProvider: () -> AppSettings
    private let selfBundleID: String?

    private var config = CotypingConfiguration.standard
    private var session: CotypingSession?
    private var generation: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var focusPrewarmTask: Task<Void, Never>?
    private var focusPrewarmFieldIdentity: String?
    private var hostPublishPollGeneration: UInt64 = 0
    private var wired = false
    private var lastLatencyMilliseconds: Int?
    private var isPostExhaustionAcceptanceArmed = false
    private var hasQueuedPostExhaustionAccept = false
    private var postExhaustionAcceptanceGeneration: UInt64 = 0
    private var pendingStreamPartial: PendingStreamPartial?
    private var isStreamDrainScheduled = false
    private var lastAcceptedTail: AcceptedSuggestionTail?
    private var lastAcceptanceAt: Date?
    private var pendingInsertionConsumedCount: Int?
    private var suggestionAnchorCache = CotypingSuggestionAnchorCache()
    private var clipboardPrefaceMemo: CotypingClipboardPrefaceMemo?
    private var pendingSpeculativeSignature: String?
    private var pendingSpeculativeResult: PendingSpeculativeResult?
    private let spellChecker = CotypingSpellChecker()
    private let clipboardProvider = CotypingClipboardProvider()
    private let clipboardRelevanceFilter = CotypingClipboardRelevanceFilter()
    private nonisolated static let axPrecedingWindowLimit = 4096
    private nonisolated static let hostPublishWaitCeilingMs = 400
    private nonisolated static let hostPublishFirstPollIntervalMs = 10
    private nonisolated static let hostPublishPollIntervalMs = 30
    private nonisolated static let freshSnapshotReuseWindowMilliseconds = 30
    private nonisolated static let postExhaustionAcceptanceWindowSeconds: TimeInterval = 0.8

    init(
        engine: CotypingCompleting,
        settingsProvider: @escaping () -> AppSettings,
        learningStore: CotypingLearningStore,
        selfBundleID: String? = Bundle.main.bundleIdentifier
    ) {
        self.engine = engine
        self.learningStore = learningStore
        self.settingsProvider = settingsProvider
        self.selfBundleID = selfBundleID
        self.focusTracker = CotypingFocusTracker()
        let suppressionController = CotypingInputSuppressionController()
        self.inputMonitor = CotypingInputMonitor(suppressionController: suppressionController)
        self.inputSourceMonitor = CotypingKeyboardInputSourceMonitor()
        self.overlay = CotypingOverlayController()
        self.inserter = CotypingInserter(suppressionController: suppressionController)
    }

    // MARK: - Lifecycle

    /// Start or stop to match the current settings + permissions. Idempotent —
    /// call on launch and whenever the cotyping settings change.
    func applySettings() {
        let settings = settingsProvider()
        guard settings.cotypingEnabled else { stop(reason: "Cotyping is off."); return }
        guard CotypingAXHelper.isTrusted else {
            stop(reason: "Accessibility permission needed.")
            return
        }
        guard CGPreflightListenEventAccess() else {
            stop(reason: "Input Monitoring permission needed.")
            return
        }
        start()
    }

    private func start() {
        guard !isRunning else { return }
        wireIfNeeded()
        guard inputMonitor.start() else {
            state = .disabled("Input Monitoring permission needed.")
            return
        }
        focusTracker.start()
        isRunning = true
        state = .idle
    }

    func stop(reason: String? = nil) {
        cancelPendingGenerationWork()
        clearSuggestion()
        focusTracker.stop()
        inputMonitor.stop()
        isRunning = false
        if let reason { state = .disabled(reason) } else { state = .idle }
    }

    private func wireIfNeeded() {
        guard !wired else { return }
        wired = true
        focusTracker.onChange = { [weak self] focus in self?.handleFocusChange(focus) }
        inputMonitor.onKey = { [weak self] event in self?.handleKey(event) }
        inputMonitor.onAcceptKey = { [weak self] scope in self?.acceptFromTap(scope) ?? false }
        inputMonitor.acceptGate = { [weak self] in
            guard let self else { return false }
            return self.overlay.isVisible || self.isPostExhaustionAcceptanceArmed
        }
        inputMonitor.acceptKeyCodeProvider = { [weak self] in
            self?.settingsProvider().cotypingAcceptKey.keyCode ?? 48
        }
        inputMonitor.fullAcceptKeyCodeProvider = { [weak self] in
            self?.settingsProvider().cotypingFullAcceptKey.keyCode
        }
    }

    // MARK: - Input handling

    private func handleKey(_ event: CotypingInputEvent) {
        guard isRunning else { return }
        switch event.kind {
        case .acceptance, .fullAcceptance:
            break // owned by the accept tap
        case .textMutation:
            if advanceActiveSessionIfTypedCharactersMatch(event.characters) {
                return
            }
            scheduleGenerationAfterHostPublishDelay()
        case .dismissal, .navigation, .shortcut, .other:
            cancelPendingGenerationWork()
            clearSuggestion()
            state = .idle
        }
    }

    private func handleFocusChange(_ focus: CotypingFocus) {
        guard isRunning else { return }
        // Drop a live suggestion when focus leaves the field/app it belongs to.
        if let session,
           Self.shouldClearActiveSessionOnFocusChange(
               session,
               liveField: focus.field,
               pendingInsertionConsumedCount: pendingInsertionConsumedCount) {
            clearSuggestion()
        }
        // Surface a disabled reason in the UI while idle (no live suggestion).
        if session == nil, state == .idle || isDisabledState {
            let settings = settingsProvider()
            if let reason = CotypingAvailability.disabledReason(
                enabled: settings.cotypingEnabled,
                excludedApps: settings.cotypingExcludedAppList,
                suggestInIntegratedTerminals: settings.cotypingSuggestInIntegratedTerminals,
                selfBundleID: selfBundleID, focus: focus),
               case .unsupported = focus.capability {
                // Only reflect hard "not a text field" states passively; avoid
                // flapping the label on every transient focus change.
                state = .disabled(reason)
            } else if case .supported = focus.capability {
                state = .idle
            }
        }
        scheduleFocusPrewarm(for: focus)
    }

    private var isDisabledState: Bool {
        if case .disabled = state { return true }
        return false
    }

    // MARK: - Generation

    private func scheduleFocusPrewarm(for focus: CotypingFocus) {
        guard isRunning,
              case .supported = focus.capability,
              let field = focus.field else {
            focusPrewarmTask?.cancel()
            focusPrewarmTask = nil
            focusPrewarmFieldIdentity = nil
            return
        }

        let fieldIdentity = Self.prewarmFieldIdentity(for: field)
        guard fieldIdentity != focusPrewarmFieldIdentity else { return }

        focusPrewarmTask?.cancel()
        focusPrewarmTask = nil
        guard session == nil, state == .idle else {
            return
        }
        let settings = settingsProvider()
        guard CotypingAvailability.disabledReason(
            enabled: settings.cotypingEnabled,
            excludedApps: settings.cotypingExcludedAppList,
            suggestInIntegratedTerminals: settings.cotypingSuggestInIntegratedTerminals,
            selfBundleID: selfBundleID,
            focus: focus) == nil,
              let request = buildRequest(for: field, settings: settings, generation: generation)
        else {
            return
        }

        focusPrewarmFieldIdentity = fieldIdentity
        focusPrewarmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            try? await self?.engine.prewarm(for: request)
        }
    }

    private func scheduleGeneration(consumedDelayMilliseconds: Int = 0) {
        pendingSpeculativeSignature = nil
        pendingSpeculativeResult = nil
        debounceTask?.cancel()
        generationTask?.cancel()
        generationTask = nil
        generation &+= 1
        let work = generation
        clearSuggestion(releasePostExhaustionWindow: !isPostExhaustionAcceptanceArmed)
        state = .debouncing
        let delay = CotypingDebouncePolicy.milliseconds(
            lastLatencyMilliseconds: lastLatencyMilliseconds,
            configured: settingsProvider().cotypingDebounceMs,
            consumedDelayMilliseconds: consumedDelayMilliseconds)
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            self?.replaceGenerationWork(for: work)
        }
    }

    private func scheduleGenerationAfterHostPublishDelay(baseline explicitBaseline: CotypingField? = nil) {
        cancelPendingGenerationWork()
        let baseline = explicitBaseline ?? focusTracker.focus.field
        let pollGeneration = hostPublishPollGeneration
        let keystrokeUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.hostPublishFirstPollIntervalMs)) { [weak self] in
            self?.pollForHostPublish(
                baseline: baseline,
                pollGeneration: pollGeneration,
                elapsedMs: Self.hostPublishFirstPollIntervalMs,
                keystrokeUptimeNanoseconds: keystrokeUptimeNanoseconds
            )
        }
    }

    private func pollForHostPublish(
        baseline: CotypingField?,
        pollGeneration: UInt64,
        elapsedMs: Int,
        keystrokeUptimeNanoseconds: UInt64
    ) {
        guard isRunning, pollGeneration == hostPublishPollGeneration else { return }
        let focus = focusTracker.refreshNow()
        guard isRunning, pollGeneration == hostPublishPollGeneration else { return }
        let nextElapsed = elapsedMs + Self.hostPublishPollIntervalMs

        if Self.hostPublishDidMove(from: baseline, to: focus.field) {
            let consumed = Self.elapsedMilliseconds(since: keystrokeUptimeNanoseconds)
            if let field = focus.field,
               field.contentSignature == pendingSpeculativeSignature {
                _ = applyPendingSpeculativeResultIfReady(publishedField: field)
                return
            }
            pendingSpeculativeSignature = nil
            pendingSpeculativeResult = nil
            if let field = focus.field,
               advanceActiveSessionIfPublishedTextMatches(field, consumedDelayMilliseconds: consumed) {
                return
            }
            if let current = session,
               Self.shouldAwaitPostInsertionSync(
                   current,
                   liveField: focus.field,
                   pendingInsertionConsumedCount: pendingInsertionConsumedCount),
               nextElapsed < Self.hostPublishWaitCeilingMs {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.hostPublishPollIntervalMs)) { [weak self] in
                    self?.pollForHostPublish(
                        baseline: baseline,
                        pollGeneration: pollGeneration,
                        elapsedMs: nextElapsed,
                        keystrokeUptimeNanoseconds: keystrokeUptimeNanoseconds
                    )
                }
                return
            }
            scheduleGeneration(consumedDelayMilliseconds: consumed)
            return
        }

        guard nextElapsed < Self.hostPublishWaitCeilingMs else {
            pendingSpeculativeSignature = nil
            pendingSpeculativeResult = nil
            scheduleGeneration(consumedDelayMilliseconds: Self.elapsedMilliseconds(since: keystrokeUptimeNanoseconds))
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.hostPublishPollIntervalMs)) { [weak self] in
            self?.pollForHostPublish(
                baseline: baseline,
                pollGeneration: pollGeneration,
                elapsedMs: nextElapsed,
                keystrokeUptimeNanoseconds: keystrokeUptimeNanoseconds
            )
        }
    }

    nonisolated static func hostPublishDidMove(from baseline: CotypingField?, to current: CotypingField?) -> Bool {
        guard let baseline else { return current != nil }
        guard let current else { return true }
        return current.contentSignature != baseline.contentSignature
            || current.processID != baseline.processID
            || current.bundleID != baseline.bundleID
            || current.role != baseline.role
            || knownFocusIdentityDidMove(from: baseline, to: current)
            || suggestionAnchorIdentity(for: current) != suggestionAnchorIdentity(for: baseline)
    }

    private nonisolated static func knownFocusIdentityDidMove(
        from baseline: CotypingField,
        to current: CotypingField
    ) -> Bool {
        guard let original = baseline.focusIdentityKey,
              let live = current.focusIdentityKey else {
            return false
        }
        return original != live
    }

    private nonisolated static func elapsedMilliseconds(since uptimeNanoseconds: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- uptimeNanoseconds) / 1_000_000)
    }

    private func cancelPendingGenerationWork() {
        focusPrewarmTask?.cancel()
        focusPrewarmTask = nil
        hostPublishPollGeneration &+= 1
        pendingSpeculativeSignature = nil
        pendingSpeculativeResult = nil
        debounceTask?.cancel()
        debounceTask = nil
        generationTask?.cancel()
        generationTask = nil
        generation &+= 1
    }

    private func replaceGenerationWork(for work: UInt64) {
        guard work == generation, isRunning else { return }
        generationTask?.cancel()
        generationTask = Task { [weak self] in
            guard let self, !Task.isCancelled, work == self.generation else { return }
            defer {
                if self.generation == work {
                    self.generationTask = nil
                }
            }
            await self.generate(work: work)
        }
    }

    private func advanceActiveSessionIfPublishedTextMatches(
        _ liveField: CotypingField,
        consumedDelayMilliseconds: Int
    ) -> Bool {
        guard let current = session,
              let advanced = Self.sessionReconciledByPublishedTyping(current, liveField: liveField) else {
            return false
        }

        session = advanced
        if advanced.isExhausted {
            clearSuggestion()
            state = .idle
            scheduleGeneration(consumedDelayMilliseconds: consumedDelayMilliseconds)
            return true
        }

        pendingInsertionConsumedCount = nil
        let remainingText = advanced.remainingText
        let placement = self.placement(for: liveField)
        if !overlay.shouldHoldInlineReanchor(
            text: remainingText,
            caretRect: liveField.caretRect,
            style: liveField.fieldStyle,
            placement: placement,
            millisecondsSinceLastAcceptance: millisecondsSinceLastAcceptance(),
            inputFrameRect: liveField.inputFrameRect,
            isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(liveField.precedingText)) {
            showOverlay(text: remainingText, field: liveField, placement: placement)
        }
        syncAcceptInterception()
        lastSuggestion = remainingText
        state = .ready(text: remainingText)
        return true
    }

    private func advanceActiveSessionIfTypedCharactersMatch(_ typedCharacters: String) -> Bool {
        guard let current = session,
              let advanced = Self.sessionAdvancedByTypedCharacters(
                  current,
                  typedCharacters: typedCharacters) else {
            return false
        }

        cancelPendingGenerationWork()
        session = advanced
        if advanced.isExhausted {
            clearSuggestion()
            state = .idle
            scheduleGenerationAfterHostPublishDelay(baseline: current.field)
            return true
        }

        let remainingText = advanced.remainingText
        if !overlay.advanceInline(
            to: remainingText,
            insertedText: typedCharacters,
            isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(current.field.precedingText)) {
            showOverlay(text: remainingText, field: current.field)
        }
        syncAcceptInterception()
        lastSuggestion = remainingText
        state = .ready(text: remainingText)
        return true
    }

    private func generate(work: UInt64) async {
        guard work == generation, isRunning else { return }
        let settings = settingsProvider()
        let focus = refreshFocusForPrediction(settings: settings)

        if let reason = CotypingAvailability.disabledReason(
            enabled: settings.cotypingEnabled,
            excludedApps: settings.cotypingExcludedAppList,
            excludedDomains: settings.cotypingExcludedDomainList,
            suggestInIntegratedTerminals: settings.cotypingSuggestInIntegratedTerminals,
            selfBundleID: selfBundleID, focus: focus) {
            state = .disabled(reason)
            return
        }
        guard let field = focus.field else { state = .idle; return }

        // Emoji: an explicit `:shortcode` intent wins over autocorrect and the LLM.
        if settings.cotypingEmoji, let emoji = CotypingEmoji.match(trailing: field.precedingText) {
            startSession(CotypingSession(field: field, fullText: emoji.glyph, kind: .emoji(shortcode: emoji.shortcode)))
            showOverlay(text: "\(emoji.glyph) :\(emoji.shortcode):", field: field, acceptanceText: emoji.glyph)
            syncAcceptInterception()
            lastSuggestion = emoji.glyph
            state = .ready(text: emoji.glyph)
            return
        }

        // Macros: an explicit `/expr` (math, date, unit, currency, random) wins too.
        if settings.cotypingMacros, let macro = CotypingMacro.match(trailing: field.precedingText) {
            startSession(CotypingSession(field: field, fullText: macro.result.insertion, kind: .macro))
            showOverlay(text: macro.result.preview, field: field, acceptanceText: macro.result.insertion)
            syncAcceptInterception()
            lastSuggestion = macro.result.insertion
            state = .ready(text: macro.result.insertion)
            return
        }

        // Autocorrect: offer to fix the trailing word before spending an LLM call.
        switch typoDecision(for: field.precedingText, enabled: settings.cotypingAutocorrect) {
        case .offerCorrection(let word, let corrected):
            startSession(CotypingSession(field: field, fullText: corrected, kind: .correction(typoWord: word)))
            showOverlay(text: corrected, field: field)
            syncAcceptInterception()
            lastSuggestion = corrected
            state = .ready(text: corrected)
            return
        case .suppress:
            clearSuggestion()
            state = .idle
            return
        case .proceed:
            break
        }

        if restoreSuggestionFromAnchorCache(field: field, work: work) {
            return
        }

        guard let request = buildRequest(for: field, settings: settings, generation: work) else {
            state = .idle
            return
        }

        state = .generating
        let start = Date()
        do {
            // Stream: paint ghost text as tokens arrive instead of waiting for the
            // whole completion only when the user enabled streamed suggestions.
            // Even when partial painting is off, keep the streaming transport so
            // the HTTP client can stop at the same decode boundary as Cotabby.
            let streamPartials = settings.cotypingStreamSuggestionsWhileGenerating
            let result = try await engine.generateStreaming(request) { [weak self] partial in
                guard streamPartials else { return }
                Task { @MainActor in self?.queueStreamPartial(partial, work: work, field: field) }
            }
            guard work == generation, isRunning else { return }
            guard let liveField = validatedLiveFieldForGeneratedResult(
                originalField: field,
                settings: settings) else {
                clearStaleGeneratedResult()
                return
            }
            let pendingAcceptedTail = lastAcceptedTail
            lastAcceptedTail = nil
            _ = applyGenerationResult(
                result,
                field: liveField,
                work: work,
                latencyMilliseconds: Int(Date().timeIntervalSince(start) * 1000),
                pendingAcceptedTail: pendingAcceptedTail)
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            guard work == generation else { return }
            state = .failed(shortError(error))
            CotypingStatsStore.shared.recordError()
        }
    }

    private func buildRequest(
        for field: CotypingField,
        settings: AppSettings,
        generation: UInt64
    ) -> CotypingRequest? {
        var cfg = config
        cfg.maxResponseTokens = settings.cotypingMaxResponseTokens
        cfg.maxResponseWords = settings.cotypingMaxWords
        let clipboardSnippet = pinnedClipboardContext(
            for: field,
            config: cfg,
            enabled: settings.cotypingUseClipboard)
        let learnedExamples = settings.cotypingUseLocalLearning
            ? learningStore.examples(
                for: field,
                limit: settings.cotypingLearningExamplesInPrompt)
            : []
        return CotypingRequestBuilder.build(
            field: field, config: cfg,
            personalization: settings.cotypingPersonalization, generation: generation,
            clipboardContext: clipboardSnippet,
            learnedExamples: learnedExamples)
    }

    private func pinnedClipboardContext(
        for field: CotypingField,
        config: CotypingConfiguration,
        enabled: Bool
    ) -> String? {
        guard enabled else {
            clipboardPrefaceMemo = nil
            clipboardRelevanceFilter.reset()
            return nil
        }
        let identityKey = Self.suggestionAnchorIdentity(for: field)
        let changeCount = clipboardProvider.changeCount
        let prefix = CotypingPrefixWindow.truncatedPrefix(
            from: field.precedingText,
            maxCharacters: config.maxPrefixCharacters,
            maxWords: config.maxPrefixWords)
        let resolution = CotypingClipboardPrefaceResolver.resolve(
            rawClipboard: clipboardProvider.currentText,
            pasteboardChangeCount: changeCount,
            precedingText: prefix,
            identityKey: identityKey,
            memo: clipboardPrefaceMemo,
            relevanceFilter: clipboardRelevanceFilter)
        clipboardPrefaceMemo = resolution.memo
        return resolution.value
    }

    private func refreshFocusForPrediction(settings: AppSettings) -> CotypingFocus {
        let includeSurface = settings.cotypingUseAppContext
        let includeURL = !settings.cotypingExcludedDomainList.isEmpty
        let includeStyle = settings.cotypingMatchHostStyle
        guard !includeSurface, !includeURL, !includeStyle else {
            return focusTracker.refreshNow(
                includeSurface: includeSurface,
                includeURL: includeURL,
                includeStyle: includeStyle)
        }
        return focusTracker.refreshIfStale(
            maxAgeMilliseconds: Self.freshSnapshotReuseWindowMilliseconds)
    }

    private func validatedLiveFieldForGeneratedResult(
        originalField: CotypingField,
        settings: AppSettings
    ) -> CotypingField? {
        let focus = refreshFocusForPrediction(settings: settings)
        if let reason = CotypingAvailability.disabledReason(
            enabled: settings.cotypingEnabled,
            excludedApps: settings.cotypingExcludedAppList,
            excludedDomains: settings.cotypingExcludedDomainList,
            suggestInIntegratedTerminals: settings.cotypingSuggestInIntegratedTerminals,
            selfBundleID: selfBundleID,
            focus: focus) {
            state = .disabled(reason)
            return nil
        }
        guard Self.isCurrentGenerationTarget(originalField, liveField: focus.field) else {
            return nil
        }
        return focus.field
    }

    private func clearStaleGeneratedResult() {
        clearSuggestion()
        if !isDisabledState {
            state = .idle
        }
    }

    private func applyGenerationResult(
        _ result: CotypingNormalizationResult,
        field: CotypingField,
        work: UInt64,
        latencyMilliseconds: Int,
        pendingAcceptedTail: AcceptedSuggestionTail?
    ) -> Bool {
        guard work == generation, isRunning else { return false }
        lastLatencyMilliseconds = latencyMilliseconds
        CotypingStatsStore.shared.recordGeneration(latencyMs: latencyMilliseconds)
        let text = result.text
        guard !text.isEmpty else {
            clearSuggestion()
            state = .idle
            return false
        }
        if let pendingAcceptedTail,
           Self.isStaleAcceptanceEcho(
               resultText: text,
               acceptedChunk: pendingAcceptedTail.text,
               currentPrecedingText: field.precedingText,
               acceptedPrecedingText: pendingAcceptedTail.precedingText) {
            clearSuggestion()
            state = .idle
            return false
        }
        guard seamVerdict(precedingText: field.precedingText, completion: text) == .allow else {
            clearSuggestion()
            state = .idle
            return false
        }
        suggestionAnchorCache.record(
            identityKey: Self.suggestionAnchorIdentity(for: field),
            precedingText: field.precedingText,
            fullText: text)
        startSession(CotypingSession(field: field, fullText: text, kind: .continuation))
        showOverlay(text: text, field: field)
        syncAcceptInterception()
        lastSuggestion = text
        state = .ready(text: text)
        flushQueuedPostExhaustionAcceptIfNeeded()
        return true
    }

    private func restoreSuggestionFromAnchorCache(field: CotypingField, work: UInt64) -> Bool {
        guard work == generation,
              field.selectionLength == 0,
              !field.isSecure else { return false }
        guard let text = suggestionAnchorCache.remainder(
            identityKey: Self.suggestionAnchorIdentity(for: field),
            precedingText: field.precedingText),
              !text.isEmpty else { return false }

        guard !CotypingTrailingDuplicationFilter.duplicatesTrailingText(
            text,
            trailingText: field.trailingText) else {
            return false
        }
        if let pendingAcceptedTail = lastAcceptedTail,
           Self.isStaleAcceptanceEcho(
               resultText: text,
               acceptedChunk: pendingAcceptedTail.text,
               currentPrecedingText: field.precedingText,
               acceptedPrecedingText: pendingAcceptedTail.precedingText) {
            return false
        }
        guard seamVerdict(precedingText: field.precedingText, completion: text) == .allow else {
            return false
        }

        lastAcceptedTail = nil
        startSession(CotypingSession(field: field, fullText: text, kind: .continuation))
        showOverlay(text: text, field: field)
        syncAcceptInterception()
        lastSuggestion = text
        state = .ready(text: text)
        flushQueuedPostExhaustionAcceptIfNeeded()
        return true
    }

    private func dispatchSpeculativePostAcceptanceGeneration(
        from liveField: CotypingField,
        insertionText: String,
        deletingTrailingCharacters: Int
    ) {
        guard !insertionText.isEmpty else { return }
        let optimisticField = Self.optimisticFieldAfterAcceptance(
            liveField,
            insertionText: insertionText,
            deletingTrailingCharacters: deletingTrailingCharacters)
        let settings = settingsProvider()
        guard case .proceed = typoDecision(
            for: optimisticField.precedingText,
            enabled: settings.cotypingAutocorrect) else {
            return
        }

        generation &+= 1
        let work = generation
        guard let request = buildRequest(for: optimisticField, settings: settings, generation: work) else { return }
        let signature = optimisticField.contentSignature
        pendingSpeculativeSignature = signature
        pendingSpeculativeResult = nil
        state = .generating
        let start = Date()

        debounceTask?.cancel()
        debounceTask = nil
        generationTask?.cancel()
        generationTask = Task { [weak self] in
            do {
                guard let self else { return }
                defer {
                    if self.generation == work {
                        self.generationTask = nil
                    }
                }
                guard !Task.isCancelled, work == self.generation else { return }
                let result = try await self.engine.generate(request)
                guard !Task.isCancelled else { return }
                self.finishSpeculativeGeneration(
                    result,
                    optimisticField: optimisticField,
                    work: work,
                    latencyMilliseconds: Int(Date().timeIntervalSince(start) * 1000),
                    signature: signature)
            } catch is CancellationError {
                return
            } catch let urlError as URLError where urlError.code == .cancelled {
                return
            } catch {
                self?.failSpeculativeGeneration(work: work, signature: signature)
            }
        }
    }

    private func finishSpeculativeGeneration(
        _ result: CotypingNormalizationResult,
        optimisticField: CotypingField,
        work: UInt64,
        latencyMilliseconds: Int,
        signature: String
    ) {
        guard work == generation,
              pendingSpeculativeSignature == signature,
              isRunning else { return }
        let settings = settingsProvider()
        let focus = focusTracker.refreshNow(
            includeSurface: settings.cotypingUseAppContext,
            includeURL: !settings.cotypingExcludedDomainList.isEmpty,
            includeStyle: settings.cotypingMatchHostStyle)
        if let publishedField = focus.field,
           publishedField.contentSignature == signature {
            _ = applySpeculativeResult(
                result,
                publishedField: publishedField,
                work: work,
                latencyMilliseconds: latencyMilliseconds,
                signature: signature)
            return
        }
        pendingSpeculativeResult = PendingSpeculativeResult(
            result: result,
            work: work,
            optimisticField: optimisticField,
            latencyMilliseconds: latencyMilliseconds)
    }

    private func failSpeculativeGeneration(work: UInt64, signature: String) {
        guard work == generation,
              pendingSpeculativeSignature == signature,
              isRunning else { return }
        pendingSpeculativeSignature = nil
        pendingSpeculativeResult = nil
        scheduleGeneration(consumedDelayMilliseconds: 0)
    }

    private func applyPendingSpeculativeResultIfReady(publishedField: CotypingField) -> Bool {
        guard let signature = pendingSpeculativeSignature,
              publishedField.contentSignature == signature else { return false }
        guard let pending = pendingSpeculativeResult else { return true }
        return applySpeculativeResult(
            pending.result,
            publishedField: publishedField,
            work: pending.work,
            latencyMilliseconds: pending.latencyMilliseconds,
            signature: signature)
    }

    private func applySpeculativeResult(
        _ result: CotypingNormalizationResult,
        publishedField: CotypingField,
        work: UInt64,
        latencyMilliseconds: Int,
        signature: String
    ) -> Bool {
        guard work == generation,
              pendingSpeculativeSignature == signature,
              publishedField.contentSignature == signature else { return false }
        pendingSpeculativeSignature = nil
        pendingSpeculativeResult = nil
        let pendingAcceptedTail = lastAcceptedTail
        lastAcceptedTail = nil
        return applyGenerationResult(
            result,
            field: publishedField,
            work: work,
            latencyMilliseconds: latencyMilliseconds,
            pendingAcceptedTail: pendingAcceptedTail)
    }

    /// Coalesces streamed partials to one main-queue render pass. Tokens can
    /// arrive faster than AppKit can relayout the overlay; latest-wins keeps the
    /// visible ghost fresh without stacking window updates on the main actor.
    private func queueStreamPartial(_ result: CotypingNormalizationResult, work: UInt64, field: CotypingField) {
        guard work == generation, isRunning else { return }
        pendingStreamPartial = PendingStreamPartial(result: result, work: work, field: field)
        guard !isStreamDrainScheduled else { return }
        isStreamDrainScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.drainStreamPartial()
        }
    }

    private func drainStreamPartial() {
        isStreamDrainScheduled = false
        guard let pending = pendingStreamPartial else { return }
        pendingStreamPartial = nil
        renderStreamPartial(pending.result, work: pending.work, field: pending.field)
    }

    /// Renders a streamed partial. Monotonic: ignores reordered/shorter partials
    /// so the ghost only grows.
    private func renderStreamPartial(_ result: CotypingNormalizationResult, work: UInt64, field: CotypingField) {
        guard work == generation, isRunning, !result.text.isEmpty else { return }
        let settings = settingsProvider()
        guard let liveField = validatedLiveFieldForGeneratedResult(
            originalField: field,
            settings: settings) else {
            clearStaleGeneratedResult()
            return
        }
        guard CotypingSeamGuard.allowsStreamedPartial(
            precedingText: liveField.precedingText,
            completion: result.text
        ) else { return }
        let currentlyRendered = session?.field.contentSignature == liveField.contentSignature
            ? session?.fullText
            : nil
        guard CotypingStreamedGhostTextPolicy.isRenderableExtension(
            candidate: result.text,
            currentlyRendered: currentlyRendered) else {
            return
        }
        startSession(CotypingSession(field: liveField, fullText: result.text, kind: .continuation))
        showOverlay(text: result.text, field: liveField)
        syncAcceptInterception()
        lastSuggestion = result.text
        state = .ready(text: result.text)
    }

    private func seamVerdict(precedingText: String, completion: String) -> CotypingSeamGuard.Verdict {
        CotypingSeamGuard.verdict(
            precedingText: precedingText,
            completion: completion,
            isKnownWord: { !spellChecker.isTypo($0) })
    }

    /// Resolves the typo gate for the trailing word using the native spell checker.
    private func typoDecision(for precedingText: String, enabled: Bool) -> CotypingTypoDecision {
        CotypingTypoGate.resolve(
            precedingText: precedingText, enabled: enabled,
            isTypo: { spellChecker.isTypo($0) },
            bestCorrection: { spellChecker.bestCorrection(for: $0) })
    }

    /// Bundles the caret-geometry + mid-line + preference signals the overlay
    /// needs to pick inline vs popup rendering, derived from a field snapshot.
    private func placement(for field: CotypingField) -> CotypingOverlayPlacement {
        CotypingOverlayPlacement(
            caretIsExact: field.caretIsExact,
            isCaretAtEndOfLine: CotypingRenderModePolicy.isCaretAtEndOfLine(trailingText: field.trailingText),
            preference: settingsProvider().cotypingMirrorPreference)
    }

    private func showOverlay(
        text: String,
        field: CotypingField,
        placement: CotypingOverlayPlacement? = nil,
        acceptanceText: String? = nil
    ) {
        let settings = settingsProvider()
        overlay.show(
            text: text,
            caretRect: field.caretRect,
            inputFrameRect: field.inputFrameRect,
            focusIdentityKey: field.focusIdentityKey,
            style: field.fieldStyle,
            placement: placement ?? self.placement(for: field),
            acceptanceHintLabel: settings.cotypingShowAcceptKeyHint ? settings.cotypingAcceptKey.label : nil,
            acceptanceText: acceptanceText,
            isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(field.precedingText),
            fadeIn: settings.cotypingFadeInSuggestions,
            fadeDurationSeconds: settings.cotypingFadeInDurationSeconds)
    }

    // MARK: - Acceptance (called synchronously from the accept tap)

    private func acceptFromTap(_ scope: CotypingAcceptScope) -> Bool {
        guard isRunning else { return false }
        guard overlay.isVisible, var current = session else {
            if isPostExhaustionAcceptanceArmed {
                hasQueuedPostExhaustionAccept = true
                return true
            }
            return false
        }
        guard Self.overlayAllowsAcceptance(
            of: current.remainingText,
            visibleAcceptanceText: overlay.acceptanceText,
            overlayIsVisible: overlay.isVisible) else {
            clearSuggestion()
            state = .idle
            return false
        }
        let live = CotypingAXHelper.resolveFocus()

        // Typo correction: swap the misspelled word for its fix in one edit,
        // recomputed against the live text (the field may have changed).
        if case .correction(let typoWord) = current.kind {
            guard let liveField = live.field,
                  liveField.processID == current.field.processID,
                  let plan = CotypingCorrectionPlan.plan(
                      precedingText: liveField.precedingText,
                      expectedTypo: typoWord, correctedWord: current.fullText),
                  inserter.replace(deletingCharacters: plan.deletingCharacters, with: plan.replacementText) else {
                clearSuggestion()
                return false
            }
            acceptedWordCount += 1
            clearSuggestion()
            state = .idle
            return true
        }

        // Emoji: replace the trailing `:shortcode` token with the glyph.
        if case .emoji = current.kind {
            guard let liveField = live.field,
                  liveField.processID == current.field.processID,
                  let tokenLength = CotypingEmoji.trailingTokenLength(in: liveField.precedingText),
                  inserter.replace(deletingCharacters: tokenLength, with: current.fullText) else {
                clearSuggestion()
                return false
            }
            clearSuggestion()
            state = .idle
            return true
        }

        // Macro: re-scan + re-evaluate the live `/query` and swap it for the result.
        if case .macro = current.kind {
            guard let liveField = live.field,
                  liveField.processID == current.field.processID,
                  let macro = CotypingMacro.match(trailing: liveField.precedingText),
                  inserter.replace(deletingCharacters: macro.tokenLength, with: macro.result.insertion) else {
                clearSuggestion()
                return false
            }
            clearSuggestion()
            state = .idle
            return true
        }

        // Continuation: never insert into the wrong field (mouse-moved focus).
        guard Self.isAcceptanceContinuation(
            of: current,
            liveField: live.field,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount) else {
            clearSuggestion()
            return false
        }
        let remaining = current.remainingText
        guard !remaining.isEmpty else { clearSuggestion(); return false }

        let settings = settingsProvider()
        let baseChunk: String
        switch scope {
        case .whole:
            baseChunk = remaining
        case .chunk:
            switch settings.cotypingAcceptGranularity {
            case .word:
                baseChunk = Self.nextWord(
                    in: remaining,
                    autoAcceptTrailingPunctuation: settings.cotypingAutoAcceptTrailingPunctuation)
            case .phrase:
                baseChunk = Self.nextPhrase(
                    in: remaining,
                    autoAcceptTrailingPunctuation: settings.cotypingAutoAcceptTrailingPunctuation)
            }
        }
        let acceptedChunk = settings.cotypingAddSpaceAfterAccept
            ? Self.acceptanceChunkConsumingTrailingSpace(baseChunk, remainingText: remaining)
            : baseChunk
        guard !acceptedChunk.isEmpty else { return false }
        let liveField = live.field ?? current.field
        let insertionChunk = Self.insertionChunk(
            forAcceptedChunk: acceptedChunk,
            precedingText: liveField.precedingText)
        let insertionText = Self.insertionTextApplyingAutoSpace(
            insertionChunk: insertionChunk,
            acceptedChunk: acceptedChunk,
            session: current,
            addSpaceAfterAccept: settings.cotypingAddSpaceAfterAccept)
        let forwardDeleteCount = CotypingMidWord.shouldForceContinuation(
            precedingText: liveField.precedingText,
            trailingText: liveField.trailingText)
            ? CotypingMidWord.acceptedTrailingOverlapCount(
                acceptedText: insertionText,
                trailingText: liveField.trailingText)
            : 0
        let strategy = CotypingInsertionStrategySelector.select(
            forChunk: insertionText,
            pasteEnabled: settings.cotypingPasteInsertion,
            isComposingIMEActive: inputSourceMonitor.isComposingIMEActive)
        let inserted: Bool
        if insertionText.isEmpty {
            inserted = true
        } else if forwardDeleteCount > 0 {
            inserted = inserter.replaceForward(deletingCharacters: forwardDeleteCount, with: insertionText)
        } else {
            switch strategy {
            case .keystroke: inserted = inserter.insert(insertionText)
            case .paste: inserted = inserter.insertViaPaste(insertionText)
            }
        }
        guard inserted else { return false }
        lastAcceptanceAt = Date()
        CotypingStatsStore.shared.recordAccept(charsAccepted: acceptedChunk.count)
        if settings.cotypingUseLocalLearning {
            learningStore.recordAccepted(field: live.field ?? current.field, acceptedText: acceptedChunk)
        }

        acceptedWordCount += Self.acceptedWordCount(in: acceptedChunk)
        current = current.advanced(by: acceptedChunk.count)
        session = current

        if current.isExhausted {
            pendingInsertionConsumedCount = nil
            lastAcceptedTail = AcceptedSuggestionTail(text: acceptedChunk, precedingText: liveField.precedingText)
            clearSuggestion()
            state = .idle
            armPostExhaustionAcceptance()
            scheduleGenerationAfterHostPublishDelay(baseline: liveField)
            dispatchSpeculativePostAcceptanceGeneration(
                from: liveField,
                insertionText: insertionText,
                deletingTrailingCharacters: forwardDeleteCount)
        } else {
            // Re-anchor the ghost after the host commits the insert (AX lag).
            pendingInsertionConsumedCount = current.consumedCount
            let remainingText = current.remainingText
            if !overlay.advanceInline(
                to: remainingText,
                insertedText: insertionText,
                isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(liveField.precedingText)) {
                showOverlay(text: remainingText, field: live.field ?? current.field)
            }
            syncAcceptInterception()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(30))
                guard let self, self.overlay.isVisible, let liveSession = self.session,
                      liveSession.remainingText == remainingText else { return }
                guard !self.isAwaitingPostInsertionSync else { return }
                let focus = self.focusTracker.refreshNow()
                if let field = focus.field {
                    let placement = self.placement(for: field)
                    if self.overlay.shouldHoldInlineReanchor(
                        text: remainingText,
                        caretRect: field.caretRect,
                        style: field.fieldStyle,
                        placement: placement,
                        millisecondsSinceLastAcceptance: self.millisecondsSinceLastAcceptance(),
                        inputFrameRect: field.inputFrameRect,
                        isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(field.precedingText)) {
                        return
                    }
                    self.showOverlay(text: remainingText, field: field, placement: placement)
                    self.syncAcceptInterception()
                }
            }
        }
        return true
    }

    private func startSession(_ newSession: CotypingSession) {
        pendingInsertionConsumedCount = nil
        session = newSession
    }

    private func clearSuggestion(releasePostExhaustionWindow: Bool = true) {
        session = nil
        pendingInsertionConsumedCount = nil
        overlay.hide()
        pendingStreamPartial = nil
        if releasePostExhaustionWindow {
            clearPostExhaustionAcceptanceWindow()
        }
        syncAcceptInterception()
    }

    private func syncAcceptInterception() {
        inputMonitor.setAcceptActive(overlay.isVisible || isPostExhaustionAcceptanceArmed)
    }

    private func armPostExhaustionAcceptance() {
        isPostExhaustionAcceptanceArmed = true
        hasQueuedPostExhaustionAccept = false
        syncAcceptInterception()
        postExhaustionAcceptanceGeneration &+= 1
        let armedGeneration = postExhaustionAcceptanceGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.postExhaustionAcceptanceWindowSeconds) { [weak self] in
            guard let self, self.postExhaustionAcceptanceGeneration == armedGeneration else { return }
            self.releasePostExhaustionAcceptanceWindow()
        }
    }

    private func clearPostExhaustionAcceptanceWindow() {
        isPostExhaustionAcceptanceArmed = false
        hasQueuedPostExhaustionAccept = false
        postExhaustionAcceptanceGeneration &+= 1
    }

    private func releasePostExhaustionAcceptanceWindow() {
        guard isPostExhaustionAcceptanceArmed || hasQueuedPostExhaustionAccept else { return }
        clearPostExhaustionAcceptanceWindow()
        syncAcceptInterception()
    }

    private func flushQueuedPostExhaustionAcceptIfNeeded() {
        let shouldAccept = isPostExhaustionAcceptanceArmed && hasQueuedPostExhaustionAccept
        clearPostExhaustionAcceptanceWindow()
        syncAcceptInterception()
        guard shouldAccept else { return }
        _ = acceptFromTap(.chunk)
    }

    private func millisecondsSinceLastAcceptance() -> Int? {
        lastAcceptanceAt.map { Int(Date().timeIntervalSince($0) * 1000) }
    }

    private var isAwaitingPostInsertionSync: Bool {
        pendingInsertionConsumedCount != nil
    }

    // MARK: - In-app preview

    /// Runs the real pipeline (prompt + model + normalizer) on synthetic text for
    /// the in-app preview playground. No Accessibility / Input Monitoring needed.
    func previewSuggestion(precedingText: String, trailingText: String = "") async throws -> String {
        let settings = settingsProvider()
        var cfg = config
        cfg.maxResponseTokens = settings.cotypingMaxResponseTokens
        cfg.maxResponseWords = settings.cotypingMaxWords
        let field = CotypingField(
            appName: "LokalBot", bundleID: selfBundleID, processID: 0, role: "AXTextArea",
            precedingText: precedingText, trailingText: trailingText, selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: false)
        let learnedExamples = settings.cotypingUseLocalLearning
            ? learningStore.examples(
                for: field,
                limit: settings.cotypingLearningExamplesInPrompt)
            : []
        guard let request = CotypingRequestBuilder.build(
            field: field, config: cfg,
            personalization: settings.cotypingPersonalization, generation: 0,
            learnedExamples: learnedExamples) else {
            return ""
        }
        return try await engine.generate(request).text
    }

    func runQualityBenchmark() async -> CotypingBenchmarkSummary {
        let settings = settingsProvider()
        var cfg = config
        cfg.maxResponseTokens = settings.cotypingMaxResponseTokens
        cfg.maxResponseWords = settings.cotypingMaxWords
        return await CotypingBenchmarkRunner.run(
            engine: engine,
            config: cfg,
            personalization: settings.cotypingPersonalization,
            streamPartials: settings.cotypingStreamSuggestionsWhileGenerating,
            learnedExamples: { [weak self] field in
                guard let self, settings.cotypingUseLocalLearning else { return [] }
                return self.learningStore.examples(
                    for: field,
                    limit: settings.cotypingLearningExamplesInPrompt)
            })
    }

    // MARK: - Helpers

    /// First word-like acceptance chunk of `text`, preserving leading
    /// whitespace. Space-less scripts use ICU word segmentation so one accept
    /// advances by a word-sized unit instead of swallowing a whole CJK/Thai run.
    nonisolated static func nextWord(
        in text: String,
        autoAcceptTrailingPunctuation: Bool = true
    ) -> String {
        guard !text.isEmpty else { return "" }
        var index = text.startIndex
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        let tokenStart = index
        while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }

        if tokenStart < index,
           text[tokenStart].cotypingBeginsSpacelessScriptWord,
           let wordEnd = firstSegmentedWordEnd(in: text, from: tokenStart, notPast: index) {
            index = endOfCJKPunctuationRun(in: text, from: wordEnd, notPast: index)
        } else if tokenStart < index,
                  text[tokenStart].cotypingBindsToPrecedingSpacelessWord
                  || text[tokenStart].cotypingIsCJKOpeningBracket {
            index = endOfCJKPunctuationRun(
                in: text, from: tokenStart, notPast: index, includingOpeners: true)
        }

        if !autoAcceptTrailingPunctuation,
           let wordEnd = wordEndTrimmingTrailingPunctuation(in: text, from: tokenStart, to: index) {
            index = wordEnd
        }

        return String(text[text.startIndex..<index])
    }

    /// Text up to and including the next sentence/clause boundary (or the whole
    /// remaining text when there is none). Mirrors Cotabby's phrase acceptance
    /// granularity: ASCII sentence terminators, newlines, and CJK clause marks;
    /// ASCII commas stay inside the phrase.
    nonisolated static func nextPhrase(
        in text: String,
        autoAcceptTrailingPunctuation: Bool = true
    ) -> String {
        guard !text.isEmpty else { return "" }
        var accumulated = ""
        var working = text

        while !working.isEmpty {
            let chunk = nextWord(
                in: working,
                autoAcceptTrailingPunctuation: autoAcceptTrailingPunctuation)
            guard !chunk.isEmpty else { break }
            if let newlineIndex = chunk.firstIndex(of: "\n") {
                accumulated += chunk[...newlineIndex]
                return accumulated
            }
            accumulated += chunk
            working = String(working.dropFirst(chunk.count))
            if endsAtPhraseBoundary(accumulated) {
                return accumulated
            }
        }

        return accumulated
    }

    private nonisolated static func firstSegmentedWordEnd(
        in text: String,
        from start: String.Index,
        notPast limit: String.Index
    ) -> String.Index? {
        var wordEnd: String.Index?
        text.enumerateSubstrings(
            in: start..<limit,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, stop in
            wordEnd = range.upperBound
            stop = true
        }
        guard let wordEnd, wordEnd > start else { return nil }
        return min(wordEnd, limit)
    }

    private nonisolated static func endOfCJKPunctuationRun(
        in text: String,
        from start: String.Index,
        notPast limit: String.Index,
        includingOpeners: Bool = false
    ) -> String.Index {
        var cursor = start
        while cursor < limit {
            let character = text[cursor]
            guard character.cotypingBindsToPrecedingSpacelessWord
                    || (includingOpeners && character.cotypingIsCJKOpeningBracket) else {
                break
            }
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    private nonisolated static func endsAtPhraseBoundary(_ text: String) -> Bool {
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous] == " " || text[previous] == "\t" || text[previous].cotypingIsPhraseClosingPunctuation {
                index = previous
            } else {
                break
            }
        }
        guard index > text.startIndex else { return false }
        let previous = text.index(before: index)
        if text[previous].cotypingIsPhraseClauseBoundary { return true }
        guard text[previous].cotypingIsPhraseSentenceTerminator else { return false }
        if text[previous] == "." {
            return isTerminalPeriod(in: text, at: previous)
        }
        return true
    }

    private nonisolated static func wordEndTrimmingTrailingPunctuation(
        in text: String,
        from tokenStart: String.Index,
        to tokenEnd: String.Index
    ) -> String.Index? {
        var lastWordCharacterEnd: String.Index?
        var cursor = tokenStart
        while cursor < tokenEnd {
            if text[cursor].cotypingIsAcceptanceWordCharacter {
                lastWordCharacterEnd = text.index(after: cursor)
            }
            cursor = text.index(after: cursor)
        }
        guard let wordEnd = lastWordCharacterEnd, wordEnd < tokenEnd else {
            return nil
        }
        return wordEnd
    }

    nonisolated static func insertionChunk(
        forAcceptedChunk chunk: String,
        precedingText: String
    ) -> String {
        guard let lastScalar = precedingText.unicodeScalars.last,
              CharacterSet.whitespaces.contains(lastScalar) else {
            return chunk
        }
        return String(chunk.drop(while: { character in
            character.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
        }))
    }

    nonisolated static func insertionTextApplyingAutoSpace(
        insertionChunk: String,
        acceptedChunk: String,
        session: CotypingSession,
        addSpaceAfterAccept: Bool
    ) -> String {
        guard addSpaceAfterAccept,
              session.advanced(by: acceptedChunk.count).isExhausted else {
            return insertionChunk
        }
        return insertionChunkAppendingTrailingSpace(insertionChunk)
    }

    nonisolated static func insertionChunkAppendingTrailingSpace(_ chunk: String) -> String {
        guard let last = chunk.last,
              last.cotypingIsAcceptanceWordCharacter,
              !last.cotypingBeginsSpacelessScriptWord else {
            return chunk
        }
        return chunk + " "
    }

    nonisolated static func acceptanceChunkConsumingTrailingSpace(
        _ chunk: String,
        remainingText: String
    ) -> String {
        guard let last = chunk.last,
              last.cotypingIsAcceptanceWordCharacter,
              !last.cotypingBeginsSpacelessScriptWord else {
            return chunk
        }
        let remainder = remainingText.dropFirst(chunk.count)
        let trailingSpace = remainder.prefix { $0 == " " || $0 == "\t" }
        return trailingSpace.isEmpty ? chunk : chunk + trailingSpace
    }

    nonisolated static func acceptedWordCount(in text: String) -> Int {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .filter { token in
                token.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            }
            .count
    }

    private nonisolated static func isTerminalPeriod(in text: String, at periodIndex: String.Index) -> Bool {
        guard periodIndex > text.startIndex else { return true }
        let beforeIndex = text.index(before: periodIndex)
        let beforeChar = text[beforeIndex]
        if beforeChar.isNumber { return false }
        if beforeChar.isLetter {
            let priorIsLetter = beforeIndex > text.startIndex
                && text[text.index(before: beforeIndex)].isLetter
            if !priorIsLetter { return false }
            if terminalPeriodAbbreviations.contains(
                trailingLetters(in: text, endingBefore: periodIndex).lowercased()) {
                return false
            }
        }
        return true
    }

    private nonisolated static let terminalPeriodAbbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "vs", "eg", "ie", "etc", "no", "fig", "approx", "inc", "ltd"
    ]

    private nonisolated static func trailingLetters(in text: String, endingBefore index: String.Index) -> String {
        var letters: [Character] = []
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous].isLetter else { break }
            letters.append(text[previous])
            cursor = previous
        }
        return String(letters.reversed())
    }

    /// True when `liveField` is plausibly the same editable field `session` was
    /// generated against: same process/role, compatible focused-field identity
    /// when AX exposes one, and live text still anchored to the session prefix
    /// (which only grows as we accept words). Guards against accepting a stale
    /// suggestion after focus moved to another field in the same app, where the
    /// PID alone would still match.
    nonisolated static func isContinuation(of session: CotypingSession, liveField: CotypingField?) -> Bool {
        guard let liveField, liveField.processID == session.field.processID else { return false }
        guard liveField.bundleID == session.field.bundleID, liveField.role == session.field.role else { return false }
        if let originalIdentity = session.field.focusIdentityKey,
           let liveIdentity = liveField.focusIdentityKey,
           originalIdentity != liveIdentity {
            return false
        }
        let previous = session.field.precedingText
        let live = liveField.precedingText
        if live.hasPrefix(previous) { return true }
        guard previous.count >= axPrecedingWindowLimit || live.count >= axPrecedingWindowLimit else {
            return false
        }
        return hasCappedPrefixWindowOverlap(previous: previous, live: live)
    }

    nonisolated static func isAcceptanceContinuation(
        of session: CotypingSession,
        liveField: CotypingField?,
        pendingInsertionConsumedCount: Int?
    ) -> Bool {
        guard isContinuation(of: session, liveField: liveField) else { return false }
        guard let liveField else { return false }
        if shouldAwaitPostInsertionSync(
            session,
            liveField: liveField,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount) {
            return true
        }
        if isPostInsertionSyncTarget(
            session,
            liveField: liveField,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount) {
            return true
        }
        return liveField.trailingText == session.field.trailingText
    }

    nonisolated static func shouldClearActiveSessionOnFocusChange(
        _ session: CotypingSession,
        liveField: CotypingField?,
        pendingInsertionConsumedCount: Int?
    ) -> Bool {
        guard let liveField else { return true }
        if shouldAwaitPostInsertionSync(
            session,
            liveField: liveField,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount) {
            return false
        }
        if isPostInsertionSyncTarget(
            session,
            liveField: liveField,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount) {
            return false
        }
        guard isContinuation(of: session, liveField: liveField) else { return true }
        return liveField.trailingText != session.field.trailingText
    }

    nonisolated static func isCurrentGenerationTarget(
        _ originalField: CotypingField,
        liveField: CotypingField?
    ) -> Bool {
        guard let liveField else { return false }
        guard liveField.processID == originalField.processID,
              liveField.bundleID == originalField.bundleID,
              liveField.role == originalField.role,
              liveField.contentSignature == originalField.contentSignature,
              suggestionAnchorIdentity(for: liveField) == suggestionAnchorIdentity(for: originalField) else {
            return false
        }
        if let originalIdentity = originalField.focusIdentityKey,
           let liveIdentity = liveField.focusIdentityKey,
           originalIdentity != liveIdentity {
            return false
        }
        return true
    }

    nonisolated static func sessionAdvancedByPublishedTyping(
        _ session: CotypingSession,
        liveField: CotypingField?
    ) -> CotypingSession? {
        guard case .continuation = session.kind,
              let liveField,
              isContinuation(of: session, liveField: liveField) else { return nil }

        let expectedPrefix = session.field.precedingText + session.acceptedText
        guard liveField.precedingText.hasPrefix(expectedPrefix) else { return nil }
        let typed = String(liveField.precedingText.dropFirst(expectedPrefix.count))
        guard !typed.isEmpty, session.remainingText.hasPrefix(typed) else { return nil }

        return CotypingSession(
            field: liveField,
            fullText: session.fullText,
            consumedCount: min(session.fullText.count, session.consumedCount + typed.count),
            kind: session.kind)
    }

    nonisolated static func sessionReconciledByPublishedTyping(
        _ session: CotypingSession,
        liveField: CotypingField?
    ) -> CotypingSession? {
        guard case .continuation = session.kind,
              let liveField,
              isContinuation(of: session, liveField: liveField) else { return nil }

        let expectedPrefix = session.field.precedingText + session.acceptedText
        guard liveField.precedingText.hasPrefix(expectedPrefix) else { return nil }
        let typed = String(liveField.precedingText.dropFirst(expectedPrefix.count))
        if typed.isEmpty {
            return CotypingSession(
                field: liveField,
                fullText: session.fullText,
                consumedCount: session.consumedCount,
                kind: session.kind)
        }
        guard session.remainingText.hasPrefix(typed) else { return nil }
        return CotypingSession(
            field: liveField,
            fullText: session.fullText,
            consumedCount: min(session.fullText.count, session.consumedCount + typed.count),
            kind: session.kind)
    }

    nonisolated static func shouldAwaitPostInsertionSync(
        _ session: CotypingSession,
        liveField: CotypingField?,
        pendingInsertionConsumedCount: Int?
    ) -> Bool {
        guard let liveField,
              isPostInsertionSyncTarget(
                  session,
                  liveField: liveField,
                  pendingInsertionConsumedCount: pendingInsertionConsumedCount) else {
            return false
        }

        let expectedPrefix = session.field.precedingText + session.acceptedText
        guard !liveField.precedingText.hasPrefix(expectedPrefix) else {
            return false
        }

        return true
    }

    private nonisolated static func isPostInsertionSyncTarget(
        _ session: CotypingSession,
        liveField: CotypingField,
        pendingInsertionConsumedCount: Int?
    ) -> Bool {
        guard case .continuation = session.kind,
              pendingInsertionConsumedCount == session.consumedCount,
              liveField.processID == session.field.processID,
              liveField.bundleID == session.field.bundleID,
              liveField.role == session.field.role,
              liveField.selectionLength == 0 else {
            return false
        }
        if let originalIdentity = session.field.focusIdentityKey,
           let liveIdentity = liveField.focusIdentityKey,
           originalIdentity != liveIdentity {
            return false
        }
        return true
    }

    nonisolated static func sessionAdvancedByTypedCharacters(
        _ session: CotypingSession,
        typedCharacters: String
    ) -> CotypingSession? {
        guard case .continuation = session.kind,
              !typedCharacters.isEmpty,
              typedCharacters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              session.remainingText.hasPrefix(typedCharacters) else {
            return nil
        }
        return CotypingSession(
            field: session.field,
            fullText: session.fullText,
            consumedCount: min(session.fullText.count, session.consumedCount + typedCharacters.count),
            kind: session.kind)
    }

    nonisolated static func overlayAllowsAcceptance(
        of text: String,
        visibleAcceptanceText: String?,
        overlayIsVisible: Bool
    ) -> Bool {
        guard overlayIsVisible else { return true }
        return visibleAcceptanceText == text
    }

    nonisolated static func isStaleAcceptanceEcho(
        resultText: String,
        acceptedChunk: String,
        currentPrecedingText: String,
        acceptedPrecedingText: String
    ) -> Bool {
        let trimmedChunk = acceptedChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChunk.isEmpty else { return false }
        guard resultText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedChunk else { return false }
        return currentPrecedingText == acceptedPrecedingText
    }

    nonisolated static func optimisticFieldAfterAcceptance(
        _ field: CotypingField,
        insertionText: String,
        deletingTrailingCharacters: Int = 0
    ) -> CotypingField {
        var copy = field
        copy.precedingText += insertionText
        if deletingTrailingCharacters > 0 {
            copy.trailingText = String(copy.trailingText.dropFirst(deletingTrailingCharacters))
        }
        copy.selectionLength = 0
        return copy
    }

    nonisolated static func suggestionAnchorIdentity(for field: CotypingField) -> String {
        [
            String(field.processID),
            field.bundleID ?? "",
            field.appName,
            field.role,
            field.windowTitle ?? "",
            field.fieldPlaceholder ?? "",
        ].joined(separator: "\u{1f}")
    }

    nonisolated static func prewarmFieldIdentity(for field: CotypingField) -> String {
        let fieldPart: String
        if let focusIdentityKey = field.focusIdentityKey, !focusIdentityKey.isEmpty {
            fieldPart = "focus:\(focusIdentityKey)"
        } else if let frame = field.inputFrameRect {
            fieldPart = "frame:\(roundedRectIdentity(frame))"
        } else {
            fieldPart = [
                field.windowTitle ?? "",
                field.fieldPlaceholder ?? "",
            ].joined(separator: "\u{1f}")
        }
        return [
            String(field.processID),
            field.bundleID ?? "",
            field.appName,
            field.role,
            fieldPart,
        ].joined(separator: "\u{1f}")
    }

    private nonisolated static func roundedRectIdentity(_ rect: CGRect) -> String {
        [
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height,
        ]
            .map { String(Int($0.rounded())) }
            .joined(separator: ",")
    }

    private nonisolated static func hasCappedPrefixWindowOverlap(previous: String, live: String) -> Bool {
        let maxLength = min(min(previous.count, live.count), axPrecedingWindowLimit)
        let minimumOverlap = min(1024, maxLength)
        guard minimumOverlap > 0 else { return false }
        var length = maxLength
        while length >= minimumOverlap {
            if previous.suffix(length) == live.prefix(length) { return true }
            length -= 1
        }
        return false
    }

    private struct PendingStreamPartial {
        var result: CotypingNormalizationResult
        var work: UInt64
        var field: CotypingField
    }

    private struct PendingSpeculativeResult {
        var result: CotypingNormalizationResult
        var work: UInt64
        var optimisticField: CotypingField
        var latencyMilliseconds: Int
    }

    private struct AcceptedSuggestionTail {
        var text: String
        var precedingText: String
    }

    private func shortError(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

private extension Character {
    var cotypingBeginsSpacelessScriptWord: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana + Katakana
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xAC00...0xD7A3,   // Hangul syllables
             0x1100...0x11FF,   // Hangul Jamo
             0x0E00...0x0E7F,   // Thai
             0x0E80...0x0EFF,   // Lao
             0x1780...0x17FF,   // Khmer
             0x1000...0x109F,   // Myanmar
             0x20000...0x2A6DF, // CJK Unified Ideographs Extension B
             0x30000...0x3134F: // CJK Unified Ideographs Extension G
            return true
        default:
            return false
        }
    }

    var cotypingBindsToPrecedingSpacelessWord: Bool {
        cotypingIsCJKSentenceTerminator
            || cotypingIsPhraseClauseBoundary
            || cotypingIsCJKClosingPunctuation
    }

    var cotypingIsCJKSentenceTerminator: Bool {
        self == "\u{3002}" || self == "\u{FF01}" || self == "\u{FF1F}" || self == "\u{FF61}"
    }

    var cotypingIsCJKClosingPunctuation: Bool {
        self == "\u{300D}" || self == "\u{300F}" || self == "\u{FF09}"
            || self == "\u{3011}" || self == "\u{3009}" || self == "\u{300B}" || self == "\u{FF63}"
    }

    var cotypingIsCJKOpeningBracket: Bool {
        self == "\u{300C}" || self == "\u{300E}" || self == "\u{FF08}"
            || self == "\u{3010}" || self == "\u{3008}" || self == "\u{300A}" || self == "\u{FF62}"
    }

    var cotypingIsPhraseSentenceTerminator: Bool {
        self == "." || self == "!" || self == "?" || cotypingIsCJKSentenceTerminator
    }

    var cotypingIsPhraseClauseBoundary: Bool {
        self == "\u{3001}" || self == "\u{FF0C}" || self == "\u{FF64}"
    }

    var cotypingIsPhraseClosingPunctuation: Bool {
        self == "\"" || self == "'" || self == "\u{201D}" || self == "\u{2019}"
            || self == ")" || self == "]" || self == "}"
            || cotypingIsCJKClosingPunctuation
    }

    var cotypingIsAcceptanceWordCharacter: Bool {
        isLetter || isNumber
    }
}
