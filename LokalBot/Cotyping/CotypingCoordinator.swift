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
    private var focusPrewarmTask: Task<Void, Never>?
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
        self.inputMonitor = CotypingInputMonitor()
        self.inputSourceMonitor = CotypingKeyboardInputSourceMonitor()
        self.overlay = CotypingOverlayController()
        self.inserter = CotypingInserter()
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
        inputMonitor.onKey = { [weak self] kind in self?.handleKey(kind) }
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

    private func handleKey(_ kind: CotypingKeyKind) {
        guard isRunning else { return }
        switch kind {
        case .acceptance, .fullAcceptance:
            break // owned by the accept tap
        case .textMutation:
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
        if let session, !Self.isContinuation(of: session, liveField: focus.field) {
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
        focusPrewarmTask?.cancel()
        guard isRunning,
              session == nil,
              state == .idle,
              case .supported = focus.capability,
              let field = focus.field else {
            focusPrewarmTask = nil
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
            focusPrewarmTask = nil
            return
        }

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
            await self?.generate(work: work)
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
            scheduleGeneration(consumedDelayMilliseconds: consumed)
            return
        }

        let nextElapsed = elapsedMs + Self.hostPublishPollIntervalMs
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

    private nonisolated static func hostPublishDidMove(from baseline: CotypingField?, to current: CotypingField?) -> Bool {
        guard let baseline else { return current != nil }
        guard let current else { return true }
        return current.contentSignature != baseline.contentSignature
            || current.processID != baseline.processID
            || current.bundleID != baseline.bundleID
            || current.role != baseline.role
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
        generation &+= 1
    }

    private func advanceActiveSessionIfPublishedTextMatches(
        _ liveField: CotypingField,
        consumedDelayMilliseconds: Int
    ) -> Bool {
        guard let current = session,
              let advanced = Self.sessionAdvancedByPublishedTyping(current, liveField: liveField) else {
            return false
        }

        session = advanced
        if advanced.isExhausted {
            clearSuggestion()
            state = .idle
            scheduleGeneration(consumedDelayMilliseconds: consumedDelayMilliseconds)
            return true
        }

        overlay.show(
            text: advanced.remainingText,
            caretRect: liveField.caretRect,
            style: liveField.fieldStyle,
            placement: placement(for: liveField))
        syncAcceptInterception()
        lastSuggestion = advanced.remainingText
        state = .ready(text: advanced.remainingText)
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
            session = CotypingSession(field: field, fullText: emoji.glyph, kind: .emoji(shortcode: emoji.shortcode))
            overlay.show(text: "\(emoji.glyph) :\(emoji.shortcode):", caretRect: field.caretRect, style: field.fieldStyle, placement: placement(for: field))
            syncAcceptInterception()
            lastSuggestion = emoji.glyph
            state = .ready(text: emoji.glyph)
            return
        }

        // Macros: an explicit `/expr` (math, date, unit, currency, random) wins too.
        if settings.cotypingMacros, let macro = CotypingMacro.match(trailing: field.precedingText) {
            session = CotypingSession(field: field, fullText: macro.result.insertion, kind: .macro)
            overlay.show(text: macro.result.preview, caretRect: field.caretRect, style: field.fieldStyle, placement: placement(for: field))
            syncAcceptInterception()
            lastSuggestion = macro.result.insertion
            state = .ready(text: macro.result.insertion)
            return
        }

        // Autocorrect: offer to fix the trailing word before spending an LLM call.
        switch typoDecision(for: field.precedingText, enabled: settings.cotypingAutocorrect) {
        case .offerCorrection(let word, let corrected):
            session = CotypingSession(field: field, fullText: corrected, kind: .correction(typoWord: word))
            overlay.show(text: corrected, caretRect: field.caretRect, style: field.fieldStyle, placement: placement(for: field))
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
        guard let relevantClipboard = clipboardRelevanceFilter.filter(
            rawClipboard: clipboardProvider.currentText,
            pasteboardChangeCount: changeCount,
            precedingText: prefix) else {
            clipboardPrefaceMemo = nil
            return nil
        }
        if let pinned = clipboardPrefaceMemo?.valueIfReusable(
            identityKey: identityKey,
            changeCount: changeCount) {
            return pinned
        }

        let value = CotypingClipboardContext.resolve(
            rawClipboard: relevantClipboard,
            precedingText: prefix)
        if let value {
            clipboardPrefaceMemo = CotypingClipboardPrefaceMemo(
                identityKey: identityKey,
                changeCount: changeCount,
                value: value)
        } else if clipboardPrefaceMemo?.identityKey != identityKey
                    || clipboardPrefaceMemo?.changeCount != changeCount {
            clipboardPrefaceMemo = nil
        }
        return value
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
        session = CotypingSession(field: field, fullText: text, kind: .continuation)
        overlay.show(text: text, caretRect: field.caretRect, style: field.fieldStyle, placement: placement(for: field))
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
        session = CotypingSession(field: field, fullText: text, kind: .continuation)
        overlay.show(text: text, caretRect: field.caretRect, style: field.fieldStyle, placement: placement(for: field))
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

        Task { [weak self] in
            do {
                guard let self else { return }
                let result = try await self.engine.generate(request)
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
        session = CotypingSession(field: liveField, fullText: result.text, kind: .continuation)
        overlay.show(text: result.text, caretRect: liveField.caretRect, style: liveField.fieldStyle, placement: placement(for: liveField))
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
        guard Self.isContinuation(of: current, liveField: live.field) else {
            clearSuggestion()
            return false
        }
        let remaining = current.remainingText
        guard !remaining.isEmpty else { clearSuggestion(); return false }

        let chunk: String
        switch scope {
        case .whole:
            chunk = remaining
        case .chunk:
            switch settingsProvider().cotypingAcceptGranularity {
            case .word: chunk = Self.nextWord(in: remaining)
            case .phrase: chunk = Self.nextPhrase(in: remaining)
            }
        }
        guard !chunk.isEmpty else { return false }
        let liveField = live.field ?? current.field
        let forwardDeleteCount = CotypingMidWord.shouldForceContinuation(
            precedingText: liveField.precedingText,
            trailingText: liveField.trailingText)
            ? CotypingMidWord.acceptedTrailingOverlapCount(
                acceptedText: chunk,
                trailingText: liveField.trailingText)
            : 0
        let strategy = CotypingInsertionStrategySelector.select(
            forChunk: chunk,
            pasteEnabled: settingsProvider().cotypingPasteInsertion,
            isComposingIMEActive: inputSourceMonitor.isComposingIMEActive)
        let inserted: Bool
        if forwardDeleteCount > 0 {
            inserted = inserter.replaceForward(deletingCharacters: forwardDeleteCount, with: chunk)
        } else {
            switch strategy {
            case .keystroke: inserted = inserter.insert(chunk)
            case .paste: inserted = inserter.insertViaPaste(chunk)
            }
        }
        guard inserted else { return false }
        lastAcceptanceAt = Date()
        CotypingStatsStore.shared.recordAccept(charsAccepted: chunk.count)
        if settingsProvider().cotypingUseLocalLearning {
            learningStore.recordAccepted(field: live.field ?? current.field, acceptedText: chunk)
        }

        acceptedWordCount += chunk.split(whereSeparator: { $0.isWhitespace }).count
        current = current.advanced(by: chunk.count)
        session = current

        if current.isExhausted {
            lastAcceptedTail = AcceptedSuggestionTail(text: chunk, precedingText: liveField.precedingText)
            clearSuggestion()
            state = .idle
            armPostExhaustionAcceptance()
            scheduleGenerationAfterHostPublishDelay(baseline: liveField)
            dispatchSpeculativePostAcceptanceGeneration(
                from: liveField,
                insertionText: chunk,
                deletingTrailingCharacters: forwardDeleteCount)
        } else {
            // Re-anchor the ghost after the host commits the insert (AX lag).
            let remainingText = current.remainingText
            if !overlay.advanceInline(to: remainingText, insertedText: chunk) {
                overlay.show(text: remainingText, caretRect: live.field?.caretRect ?? current.field.caretRect, style: (live.field ?? current.field).fieldStyle, placement: placement(for: live.field ?? current.field))
            }
            syncAcceptInterception()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(30))
                guard let self, self.overlay.isVisible, let liveSession = self.session,
                      liveSession.remainingText == remainingText else { return }
                let focus = self.focusTracker.refreshNow()
                if let field = focus.field {
                    let placement = self.placement(for: field)
                    if self.overlay.shouldHoldInlineReanchor(
                        text: remainingText,
                        caretRect: field.caretRect,
                        style: field.fieldStyle,
                        placement: placement,
                        millisecondsSinceLastAcceptance: self.millisecondsSinceLastAcceptance()) {
                        return
                    }
                    self.overlay.show(text: remainingText, caretRect: field.caretRect, style: field.fieldStyle, placement: placement)
                    self.syncAcceptInterception()
                }
            }
        }
        return true
    }

    private func clearSuggestion(releasePostExhaustionWindow: Bool = true) {
        session = nil
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

    /// First word of `text`, including leading whitespace and one trailing space,
    /// so consecutive accepts advance cleanly word by word.
    static func nextWord(in text: String) -> String {
        var index = text.startIndex
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
        if index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        return String(text[text.startIndex..<index])
    }

    /// Text up to and including the next sentence/clause boundary (or the whole
    /// remaining text when there is none), plus one trailing space. Mirrors
    /// Cotabby's phrase acceptance granularity (CJK punctuation included).
    nonisolated static func nextPhrase(in text: String) -> String {
        let boundaries: Set<Character> = [
            ".", "!", "?", ",", ";", ":",
            "\u{3002}", "\u{ff01}", "\u{ff1f}", "\u{3001}", "\u{ff1b}", "\u{ff1a}",
        ]
        var index = text.startIndex
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if boundaries.contains(character) { break }
        }
        if index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        return String(text[text.startIndex..<index])
    }

    /// True when `liveField` is plausibly the same editable field `session` was
    /// generated against: same process, and the live preceding text still begins
    /// with the session's (which only grows as we accept words). Guards against
    /// accepting a stale suggestion after focus moved to another field in the same
    /// app, where the PID alone would still match.
    nonisolated static func isContinuation(of session: CotypingSession, liveField: CotypingField?) -> Bool {
        guard let liveField, liveField.processID == session.field.processID else { return false }
        guard liveField.bundleID == session.field.bundleID, liveField.role == session.field.role else { return false }
        let previous = session.field.precedingText
        let live = liveField.precedingText
        if live.hasPrefix(previous) { return true }
        guard previous.count >= axPrecedingWindowLimit || live.count >= axPrecedingWindowLimit else {
            return false
        }
        return hasCappedPrefixWindowOverlap(previous: previous, live: live)
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
