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
        inputMonitor.onAcceptKey = { [weak self] in self?.acceptFromTap() ?? false }
        inputMonitor.acceptGate = { [weak self] in self?.overlay.isVisible ?? false }
    }

    // MARK: - Input handling

    private func handleKey(_ kind: CotypingKeyKind) {
        guard isRunning else { return }
        switch kind {
        case .acceptance:
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
        let delay = max(50, settingsProvider().cotypingDebounceMs)
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            await self?.generate(work: work)
        }
    }

    private func generate(work: UInt64) async {
        guard work == generation, isRunning else { return }
        let settings = settingsProvider()
        let focus = focusTracker.refreshNow(includeSurface: settings.cotypingUseAppContext)

        if let reason = CotypingAvailability.disabledReason(
            enabled: settings.cotypingEnabled,
            excludedApps: settings.cotypingExcludedAppList,
            selfBundleID: selfBundleID, focus: focus) {
            state = .disabled(reason)
            return
        }
        guard let field = focus.field else { state = .idle; return }

        var cfg = config
        cfg.maxResponseTokens = settings.cotypingMaxResponseTokens
        guard let request = CotypingRequestBuilder.build(
            field: field, config: cfg,
            personalization: settings.cotypingPersonalization, generation: work) else {
            state = .idle
            return
        }

        state = .generating
        do {
            let result = try await engine.generate(request)
            guard work == generation, isRunning else { return }
            let text = result.text
            guard !text.isEmpty else {
                clearSuggestion()
                state = .idle
                return
            }
            session = CotypingSession(field: field, fullText: text)
            overlay.show(text: text, caretRect: field.caretRect)
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

    // MARK: - Acceptance (called synchronously from the accept tap)

    private func acceptFromTap() -> Bool {
        guard isRunning, overlay.isVisible, var current = session else { return false }
        // The accept tap can still be armed after focus slipped to another editable
        // field in the SAME app (a mouse click fires no keystroke to clear the
        // session). Re-read AX directly and bail unless the live field is still this
        // session's field (grown only by words we accepted), so a stale suggestion
        // is never inserted into the wrong field.
        let live = CotypingAXHelper.resolveFocus()
        guard Self.isContinuation(of: current, liveField: live.field) else {
            clearSuggestion()
            return false
        }
        let remaining = current.remainingText
        guard !remaining.isEmpty else { clearSuggestion(); return false }

        let chunk = settingsProvider().cotypingAcceptWholeSuggestion
            ? remaining
            : Self.nextWord(in: remaining)
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
            overlay.show(text: remainingText, caretRect: live.field?.caretRect ?? current.field.caretRect)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(30))
                guard let self, self.overlay.isVisible, let live = self.session,
                      live.remainingText == remainingText else { return }
                let focus = self.focusTracker.refreshNow()
                if let field = focus.field {
                    self.overlay.show(text: remainingText, caretRect: field.caretRect)
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
