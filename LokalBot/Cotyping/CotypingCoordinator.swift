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
    private let overlay: CotypingOverlayController
    private let inserter: CotypingInserter
    private let engine: CotypingCompleting
    private let settingsProvider: () -> AppSettings
    private let selfBundleID: String?

    private var config = CotypingConfiguration.standard
    private var session: CotypingSession?
    private var generation: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private var wired = false
    private var lastLatencyMilliseconds: Int?
    private let spellChecker = CotypingSpellChecker()

    init(
        engine: CotypingCompleting,
        settingsProvider: @escaping () -> AppSettings,
        selfBundleID: String? = Bundle.main.bundleIdentifier
    ) {
        self.engine = engine
        self.settingsProvider = settingsProvider
        self.selfBundleID = selfBundleID
        self.focusTracker = CotypingFocusTracker()
        self.inputMonitor = CotypingInputMonitor()
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
        debounceTask?.cancel()
        debounceTask = nil
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
        inputMonitor.acceptGate = { [weak self] in self?.overlay.isVisible ?? false }
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
            scheduleGeneration()
        case .dismissal, .navigation, .shortcut, .other:
            debounceTask?.cancel()
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
                selfBundleID: selfBundleID, focus: focus),
               case .unsupported = focus.capability {
                // Only reflect hard "not a text field" states passively; avoid
                // flapping the label on every transient focus change.
                state = .disabled(reason)
            } else if case .supported = focus.capability {
                state = .idle
            }
        }
    }

    private var isDisabledState: Bool {
        if case .disabled = state { return true }
        return false
    }

    // MARK: - Generation

    private func scheduleGeneration() {
        debounceTask?.cancel()
        generation &+= 1
        let work = generation
        clearSuggestion()
        state = .debouncing
        let delay = max(50, CotypingDebouncePolicy.milliseconds(
            lastLatencyMilliseconds: lastLatencyMilliseconds,
            configured: settingsProvider().cotypingDebounceMs))
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            await self?.generate(work: work)
        }
    }

    private func generate(work: UInt64) async {
        guard work == generation, isRunning else { return }
        let settings = settingsProvider()
        let focus = focusTracker.refreshNow(
            includeSurface: settings.cotypingUseAppContext,
            includeURL: !settings.cotypingExcludedDomainList.isEmpty,
            includeStyle: settings.cotypingMatchHostStyle)

        if let reason = CotypingAvailability.disabledReason(
            enabled: settings.cotypingEnabled,
            excludedApps: settings.cotypingExcludedAppList,
            excludedDomains: settings.cotypingExcludedDomainList,
            selfBundleID: selfBundleID, focus: focus) {
            state = .disabled(reason)
            return
        }
        guard let field = focus.field else { state = .idle; return }

        // Emoji: an explicit `:shortcode` intent wins over autocorrect and the LLM.
        if settings.cotypingEmoji, let emoji = CotypingEmoji.match(trailing: field.precedingText) {
            session = CotypingSession(field: field, fullText: emoji.glyph, kind: .emoji(shortcode: emoji.shortcode))
            overlay.show(text: "\(emoji.glyph) :\(emoji.shortcode):", caretRect: field.caretRect, style: field.fieldStyle)
            inputMonitor.setAcceptActive(overlay.isVisible)
            lastSuggestion = emoji.glyph
            state = .ready(text: emoji.glyph)
            return
        }

        // Macros: an explicit `/expr` (math, date, unit, currency, random) wins too.
        if settings.cotypingMacros, let macro = CotypingMacro.match(trailing: field.precedingText) {
            session = CotypingSession(field: field, fullText: macro.result.insertion, kind: .macro)
            overlay.show(text: macro.result.preview, caretRect: field.caretRect, style: field.fieldStyle)
            inputMonitor.setAcceptActive(overlay.isVisible)
            lastSuggestion = macro.result.insertion
            state = .ready(text: macro.result.insertion)
            return
        }

        // Autocorrect: offer to fix the trailing word before spending an LLM call.
        switch typoDecision(for: field.precedingText, enabled: settings.cotypingAutocorrect) {
        case .offerCorrection(let word, let corrected):
            session = CotypingSession(field: field, fullText: corrected, kind: .correction(typoWord: word))
            overlay.show(text: corrected, caretRect: field.caretRect, style: field.fieldStyle)
            inputMonitor.setAcceptActive(overlay.isVisible)
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

        var cfg = config
        cfg.maxResponseTokens = settings.cotypingMaxResponseTokens
        guard let request = CotypingRequestBuilder.build(
            field: field, config: cfg,
            personalization: settings.cotypingPersonalization, generation: work) else {
            state = .idle
            return
        }

        state = .generating
        let start = Date()
        do {
            // Stream: paint ghost text as tokens arrive instead of waiting for the
            // whole completion. The final result is authoritative.
            let result = try await engine.generateStreaming(request) { [weak self] partial in
                Task { @MainActor in self?.renderStreamPartial(partial, work: work, field: field) }
            }
            guard work == generation, isRunning else { return }
            lastLatencyMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
            let text = result.text
            guard !text.isEmpty else {
                clearSuggestion()
                state = .idle
                return
            }
            session = CotypingSession(field: field, fullText: text, kind: .continuation)
            overlay.show(text: text, caretRect: field.caretRect, style: field.fieldStyle)
            inputMonitor.setAcceptActive(overlay.isVisible)
            lastSuggestion = text
            state = .ready(text: text)
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            guard work == generation else { return }
            state = .failed(shortError(error))
        }
    }

    /// Renders a streamed partial (off the generation task, hopped to the main
    /// actor). Monotonic: ignores reordered/shorter partials so the ghost only grows.
    private func renderStreamPartial(_ result: CotypingNormalizationResult, work: UInt64, field: CotypingField) {
        guard work == generation, isRunning, !result.text.isEmpty else { return }
        if let session, session.field.contentSignature == field.contentSignature,
           session.fullText.count >= result.text.count { return }
        session = CotypingSession(field: field, fullText: result.text, kind: .continuation)
            overlay.show(text: result.text, caretRect: field.caretRect, style: field.fieldStyle)
        inputMonitor.setAcceptActive(overlay.isVisible)
        lastSuggestion = result.text
        state = .ready(text: result.text)
    }

    /// Resolves the typo gate for the trailing word using the native spell checker.
    private func typoDecision(for precedingText: String, enabled: Bool) -> CotypingTypoDecision {
        CotypingTypoGate.resolve(
            precedingText: precedingText, enabled: enabled,
            isTypo: { spellChecker.isTypo($0) },
            bestCorrection: { spellChecker.bestCorrection(for: $0) })
    }

    // MARK: - Acceptance (called synchronously from the accept tap)

    private func acceptFromTap(_ scope: CotypingAcceptScope) -> Bool {
        guard isRunning, overlay.isVisible, var current = session else { return false }
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
        guard !chunk.isEmpty, inserter.insert(chunk) else { return false }

        acceptedWordCount += chunk.split(whereSeparator: { $0.isWhitespace }).count
        current = current.advanced(by: chunk.count)
        session = current

        if current.isExhausted {
            clearSuggestion()
            state = .idle
        } else {
            // Re-anchor the ghost after the host commits the insert (AX lag).
            let remainingText = current.remainingText
            overlay.show(text: remainingText, caretRect: live.field?.caretRect ?? current.field.caretRect, style: (live.field ?? current.field).fieldStyle)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(30))
                guard let self, self.overlay.isVisible, let liveSession = self.session,
                      liveSession.remainingText == remainingText else { return }
                let focus = self.focusTracker.refreshNow()
                if let field = focus.field {
                    self.overlay.show(text: remainingText, caretRect: field.caretRect, style: field.fieldStyle)
                }
            }
        }
        return true
    }

    private func clearSuggestion() {
        session = nil
        overlay.hide()
        inputMonitor.setAcceptActive(false)
    }

    // MARK: - In-app preview

    /// Runs the real pipeline (prompt + model + normalizer) on synthetic text for
    /// the in-app preview playground. No Accessibility / Input Monitoring needed.
    func previewSuggestion(precedingText: String, trailingText: String = "") async throws -> String {
        let settings = settingsProvider()
        var cfg = config
        cfg.maxResponseTokens = settings.cotypingMaxResponseTokens
        let field = CotypingField(
            appName: "LokalBot", bundleID: selfBundleID, processID: 0, role: "AXTextArea",
            precedingText: precedingText, trailingText: trailingText, selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: false)
        guard let request = CotypingRequestBuilder.build(
            field: field, config: cfg,
            personalization: settings.cotypingPersonalization, generation: 0) else {
            return ""
        }
        return try await engine.generate(request).text
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
        return liveField.precedingText.hasPrefix(session.field.precedingText)
    }

    private func shortError(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
