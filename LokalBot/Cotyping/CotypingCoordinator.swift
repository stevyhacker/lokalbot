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
    /// Live flag from AppState — cotyping stays quiet while a meeting records.
    private let isMeetingRecordingActive: () -> Bool
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
    private nonisolated static let hostPublishWaitCeilingMs = 400
    private nonisolated static let hostPublishFirstPollIntervalMs = 10
    private nonisolated static let hostPublishPollIntervalMs = 30
    private nonisolated static let freshSnapshotReuseWindowMilliseconds = 30
    private nonisolated static let postExhaustionAcceptanceWindowSeconds: TimeInterval = 0.8

    init(
        engine: CotypingCompleting,
        settingsProvider: @escaping () -> AppSettings,
        learningStore: CotypingLearningStore,
        isMeetingRecordingActive: @escaping () -> Bool = { false },
        selfBundleID: String? = Bundle.main.bundleIdentifier
    ) {
        self.engine = engine
        self.learningStore = learningStore
        self.settingsProvider = settingsProvider
        self.isMeetingRecordingActive = isMeetingRecordingActive
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

    /// Called by AppState when a meeting recording starts or stops. Pausing
    /// drops any live ghost text immediately; the per-generation gate in
    /// `generate(work:)` keeps new suggestions from appearing while active.
    func meetingRecordingStateChanged(active: Bool) {
        guard isRunning else { return }
        if active {
            cancelPendingGenerationWork()
            clearSuggestion()
        }
        if let next = CotypingMeetingPause.transition(recordingActive: active, current: state) {
            state = next
        }
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
           CotypingSessionReconciler.shouldClearActiveSessionOnFocusChange(
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
              !isMeetingRecordingActive(),
              case .supported = focus.capability,
              let field = focus.field else {
            focusPrewarmTask?.cancel()
            focusPrewarmTask = nil
            focusPrewarmFieldIdentity = nil
            return
        }

        let fieldIdentity = CotypingFieldIdentity.prewarm(for: field)
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

        if CotypingSessionReconciler.hostPublishDidMove(from: baseline, to: focus.field) {
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
               CotypingSessionReconciler.shouldAwaitPostInsertionSync(
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
              let advanced = CotypingSessionReconciler.sessionReconciledByPublishedTyping(
                  current, liveField: liveField) else {
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
        markReady(remainingText)
        return true
    }

    private func advanceActiveSessionIfTypedCharactersMatch(_ typedCharacters: String) -> Bool {
        guard let current = session,
              let advanced = CotypingSessionReconciler.sessionAdvancedByTypedCharacters(
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
        markReady(remainingText)
        return true
    }

    private func generate(work: UInt64) async {
        guard work == generation, isRunning else { return }
        let settings = settingsProvider()
        if isMeetingRecordingActive() {
            clearSuggestion()
            state = .disabled(CotypingMeetingPause.reason)
            return
        }
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
            present(
                CotypingSession(field: field, fullText: emoji.glyph, kind: .emoji(shortcode: emoji.shortcode)),
                overlayText: "\(emoji.glyph) :\(emoji.shortcode):",
                acceptanceText: emoji.glyph)
            return
        }

        // Macros: an explicit `/expr` (math, date, unit, currency, random) wins too.
        if settings.cotypingMacros, let macro = CotypingMacro.match(trailing: field.precedingText) {
            present(
                CotypingSession(field: field, fullText: macro.result.insertion, kind: .macro),
                overlayText: macro.result.preview,
                acceptanceText: macro.result.insertion)
            return
        }

        // Autocorrect: offer to fix the trailing word before spending an LLM call.
        switch typoDecision(for: field.precedingText, enabled: settings.cotypingAutocorrect) {
        case .offerCorrection(let word, let corrected):
            present(
                CotypingSession(field: field, fullText: corrected, kind: .correction(typoWord: word)),
                overlayText: corrected)
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
            completeGeneration(
                result,
                targetField: field,
                work: work,
                latencyMilliseconds: Int(Date().timeIntervalSince(start) * 1000),
                holdSignature: nil)
        } catch {
            handleGenerationFailure(error, work: work, holdSignature: nil)
        }
    }

    /// Validates and applies a finished generation — the single completion path
    /// for both normal and speculative work. `holdSignature` marks a
    /// speculative generation whose target was an optimistic post-acceptance
    /// snapshot: its result may only apply once the host publishes the matching
    /// content signature; until then it is parked for the host-publish poll.
    /// Normal generations (`holdSignature == nil`) apply against the validated
    /// live field or are discarded as stale.
    private func completeGeneration(
        _ result: CotypingNormalizationResult,
        targetField: CotypingField,
        work: UInt64,
        latencyMilliseconds: Int,
        holdSignature: String?
    ) {
        guard work == generation, isRunning else { return }
        let settings = settingsProvider()

        if let signature = holdSignature {
            guard pendingSpeculativeSignature == signature else { return }
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
                optimisticField: targetField,
                latencyMilliseconds: latencyMilliseconds)
            return
        }

        guard let liveField = validatedLiveFieldForGeneratedResult(
            originalField: targetField,
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
            latencyMilliseconds: latencyMilliseconds,
            pendingAcceptedTail: pendingAcceptedTail)
    }

    /// The single failure path for both generation modes. Cancellation is never
    /// an error; a failed speculative generation falls back to a fresh normal
    /// cycle instead of surfacing (the user never asked for it).
    private func handleGenerationFailure(_ error: Error, work: UInt64, holdSignature: String?) {
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        guard work == generation else { return }
        if let signature = holdSignature {
            guard pendingSpeculativeSignature == signature, isRunning else { return }
            pendingSpeculativeSignature = nil
            pendingSpeculativeResult = nil
            scheduleGeneration(consumedDelayMilliseconds: 0)
            return
        }
        state = .failed(shortError(error))
        CotypingStatsStore.shared.recordError()
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
            learnedExamples: learnedExamples,
            wordPrefixIsValidWord: wordPrefixIsValidWord(for: field.precedingText))
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
        let identityKey = CotypingFieldIdentity.suggestionAnchor(for: field)
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
        guard CotypingSessionReconciler.isCurrentGenerationTarget(originalField, liveField: focus.field) else {
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
           CotypingSessionReconciler.isStaleAcceptanceEcho(
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
            identityKey: CotypingFieldIdentity.suggestionAnchor(for: field),
            precedingText: field.precedingText,
            fullText: text)
        present(
            CotypingSession(field: field, fullText: text, kind: .continuation),
            overlayText: text,
            flushQueuedAccept: true)
        return true
    }

    private func restoreSuggestionFromAnchorCache(field: CotypingField, work: UInt64) -> Bool {
        guard work == generation,
              field.selectionLength == 0,
              !field.isSecure else { return false }
        guard let text = suggestionAnchorCache.remainder(
            identityKey: CotypingFieldIdentity.suggestionAnchor(for: field),
            precedingText: field.precedingText),
              !text.isEmpty else { return false }

        guard !CotypingTrailingDuplicationFilter.duplicatesTrailingText(
            text,
            trailingText: field.trailingText) else {
            return false
        }
        if let pendingAcceptedTail = lastAcceptedTail,
           CotypingSessionReconciler.isStaleAcceptanceEcho(
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
        present(
            CotypingSession(field: field, fullText: text, kind: .continuation),
            overlayText: text,
            flushQueuedAccept: true)
        return true
    }

    private func dispatchSpeculativePostAcceptanceGeneration(
        from liveField: CotypingField,
        insertionText: String,
        deletingTrailingCharacters: Int
    ) {
        guard !insertionText.isEmpty else { return }
        let optimisticField = CotypingSessionReconciler.optimisticFieldAfterAcceptance(
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
            guard let self else { return }
            defer {
                if self.generation == work {
                    self.generationTask = nil
                }
            }
            guard !Task.isCancelled, work == self.generation else { return }
            do {
                let result = try await self.engine.generate(request)
                guard !Task.isCancelled else { return }
                self.completeGeneration(
                    result,
                    targetField: optimisticField,
                    work: work,
                    latencyMilliseconds: Int(Date().timeIntervalSince(start) * 1000),
                    holdSignature: signature)
            } catch {
                self.handleGenerationFailure(error, work: work, holdSignature: signature)
            }
        }
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
        present(
            CotypingSession(field: liveField, fullText: result.text, kind: .continuation),
            overlayText: result.text)
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
            bestCorrection: { spellChecker.bestCorrection(for: $0) },
            isCompletableWordPrefix: { spellChecker.isCompletableWordPrefix($0) })
    }

    /// Whether the word fragment at the caret is a valid standalone word — the
    /// normalizer's signal for accepting a whitespace-leading continuation
    /// after a fragment ("the" may be complete; "follo" must be extended).
    private func wordPrefixIsValidWord(for precedingText: String) -> Bool {
        let partial = CotypingMidWord.currentPartialWord(in: precedingText)
        guard partial.count >= 2 else { return true }
        return !spellChecker.isTypo(partial)
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
        overlay.show(
            text: text,
            caretRect: field.caretRect,
            inputFrameRect: field.inputFrameRect,
            focusIdentityKey: field.focusIdentityKey,
            style: field.fieldStyle,
            placement: placement ?? self.placement(for: field),
            acceptanceText: acceptanceText,
            isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(field.precedingText))
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
        // The visible ghost must match the session tail — a mismatch means the
        // overlay is showing stale text and accepting would insert the wrong thing.
        guard overlay.acceptanceText == current.remainingText else {
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
        guard CotypingSessionReconciler.isAcceptanceContinuation(
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
                baseChunk = CotypingAcceptanceChunker.nextWord(
                    in: remaining,
                    autoAcceptTrailingPunctuation: settings.cotypingAutoAcceptTrailingPunctuation)
            case .phrase:
                baseChunk = CotypingAcceptanceChunker.nextPhrase(
                    in: remaining,
                    autoAcceptTrailingPunctuation: settings.cotypingAutoAcceptTrailingPunctuation)
            }
        }
        let acceptedChunk = settings.cotypingAddSpaceAfterAccept
            ? CotypingAcceptanceChunker.acceptanceChunkConsumingTrailingSpace(baseChunk, remainingText: remaining)
            : baseChunk
        guard !acceptedChunk.isEmpty else { return false }
        let liveField = live.field ?? current.field
        let insertionChunk = CotypingAcceptanceChunker.insertionChunk(
            forAcceptedChunk: acceptedChunk,
            precedingText: liveField.precedingText)
        let insertionText = CotypingAcceptanceChunker.insertionTextApplyingAutoSpace(
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

        acceptedWordCount += CotypingAcceptanceChunker.acceptedWordCount(in: acceptedChunk)
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

    /// Atomically presents a suggestion. The invariant *session exists ⟺
    /// overlay visible ⟺ state == .ready ⟺ accept tap armed* is established
    /// here (and torn down in `clearSuggestion`) — never by hand at call sites.
    private func present(
        _ newSession: CotypingSession,
        overlayText: String,
        acceptanceText: String? = nil,
        flushQueuedAccept: Bool = false
    ) {
        startSession(newSession)
        showOverlay(text: overlayText, field: newSession.field, acceptanceText: acceptanceText)
        markReady(acceptanceText ?? overlayText)
        if flushQueuedAccept {
            flushQueuedPostExhaustionAcceptIfNeeded()
        }
    }

    /// The published tail of `present` — also used by the advance paths, which
    /// keep the existing overlay window and only re-arm interception + state.
    private func markReady(_ text: String) {
        syncAcceptInterception()
        lastSuggestion = text
        state = .ready(text: text)
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
            learnedExamples: learnedExamples,
            wordPrefixIsValidWord: wordPrefixIsValidWord(for: precedingText)) else {
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
