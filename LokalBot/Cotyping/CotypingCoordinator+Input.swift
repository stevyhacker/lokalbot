import Foundation

/// Focus changes, keyboard input, and host-publish reconciliation.
extension CotypingCoordinator {
    // MARK: - Input handling

    func handleKey(_ event: CotypingInputEvent) {
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

    func handleFocusChange(_ focus: CotypingFocus) {
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
                excludedDomains: settings.cotypingExcludedDomainList,
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

    var isDisabledState: Bool {
        if case .disabled = state { return true }
        return false
    }

    func scheduleGenerationAfterHostPublishDelay(baseline explicitBaseline: CotypingField? = nil) {
        cancelPendingGenerationWork()
        let baseline = explicitBaseline ?? focusTracker.focus.field
        let pollGeneration = hostPublishPollGeneration
        let keystrokeUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds

        hostPublishPollTask?.cancel()
        hostPublishPollTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.hostPublishFirstPollIntervalMs))
            guard !Task.isCancelled else { return }
            await self?.pollForHostPublish(
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
    ) async {
        guard isRunning, pollGeneration == hostPublishPollGeneration else { return }
        let focus = await focusTracker.refreshNow()
        guard isRunning, pollGeneration == hostPublishPollGeneration else { return }
        let nextElapsed = elapsedMs + Self.hostPublishPollIntervalMs

        if CotypingSessionReconciler.hostPublishDidMove(from: baseline, to: focus.field) {
            let consumed = Self.elapsedMilliseconds(since: keystrokeUptimeNanoseconds)
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
                try? await Task.sleep(for: .milliseconds(Self.hostPublishPollIntervalMs))
                guard !Task.isCancelled else { return }
                await pollForHostPublish(
                    baseline: baseline,
                    pollGeneration: pollGeneration,
                    elapsedMs: nextElapsed,
                    keystrokeUptimeNanoseconds: keystrokeUptimeNanoseconds)
                return
            }
            scheduleGeneration(consumedDelayMilliseconds: consumed)
            return
        }

        guard nextElapsed < Self.hostPublishWaitCeilingMs else {
            scheduleGeneration(consumedDelayMilliseconds: Self.elapsedMilliseconds(since: keystrokeUptimeNanoseconds))
            return
        }

        try? await Task.sleep(for: .milliseconds(Self.hostPublishPollIntervalMs))
        guard !Task.isCancelled else { return }
        await pollForHostPublish(
            baseline: baseline,
            pollGeneration: pollGeneration,
            elapsedMs: nextElapsed,
            keystrokeUptimeNanoseconds: keystrokeUptimeNanoseconds)
    }

    private nonisolated static func elapsedMilliseconds(since uptimeNanoseconds: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- uptimeNanoseconds) / 1_000_000)
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
}
