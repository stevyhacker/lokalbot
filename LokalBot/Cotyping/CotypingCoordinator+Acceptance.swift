import Foundation

/// Acceptance, session presentation, insertion bookkeeping, and teardown.
extension CotypingCoordinator {
    // MARK: - Acceptance (called synchronously from the accept tap)

    func acceptFromTap(_ scope: CotypingAcceptScope) -> Bool {
        guard let context = acceptanceContext() else { return false }
        if case .continuation = context.session.kind {
            return acceptContinuation(context, scope: scope)
        }
        return acceptReplacement(context)
    }

    private struct AcceptanceContext {
        var session: CotypingSession
        let live: CotypingAXAcceptanceSnapshot
    }

    private struct ContinuationPlan {
        let acceptedChunk: String
        let liveField: CotypingField
        let insertionText: String
        let forwardDeleteCount: Int
    }

    private func acceptanceContext() -> AcceptanceContext? {
        guard isRunning,
              CotypingAcceptanceOwnershipPolicy.shouldOwnAcceptKey(
                  overlayIsVisible: overlay.isVisible,
                  hasSession: session != nil),
              let current = session else { return nil }

        guard overlay.acceptanceText == current.remainingText else {
            rejectStaleAcceptance(resetState: true)
            return nil
        }
        freezeStreamedSuggestionForAcceptance()
        let live = CotypingAXHelper.resolveAcceptanceSnapshot(
            cachedField: focusTracker.focus.field)
        guard CotypingAcceptanceSnapshotPolicy.canAccept(
            markedTextState: live.markedTextState,
            composingInputModeActive: inputSourceMonitor.isComposingIMEActive,
            hasLiveContent: live.hasLiveContent,
            selectionLength: live.field?.selectionLength) else {
            rejectStaleAcceptance(resetState: true)
            return nil
        }
        return .init(session: current, live: live)
    }

    private func acceptReplacement(_ context: AcceptanceContext) -> Bool {
        guard let plan = CotypingReplacementAcceptancePlanner.plan(
            for: context.session,
            liveField: context.live.field),
              inserter.replace(
                  deletingCharacters: plan.deletingCharacters,
                  with: plan.replacementText) else {
            rejectStaleAcceptance()
            return false
        }
        if case .correction = context.session.kind { acceptedWordCount += 1 }
        clearSuggestion()
        state = .idle
        return true
    }

    private func acceptContinuation(
        _ context: AcceptanceContext,
        scope: CotypingAcceptScope
    ) -> Bool {
        guard CotypingSessionReconciler.isAcceptanceContinuation(
            of: context.session,
            liveField: context.live.field,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount) else {
            rejectStaleAcceptance()
            return false
        }
        let settings = settingsProvider()
        guard let plan = continuationPlan(
            for: context,
            scope: scope,
            settings: settings) else { return false }
        guard insert(plan) else {
            rejectStaleAcceptance(resetState: true)
            return false
        }
        recordAcceptance(plan, settings: settings)
        advanceContinuation(
            context.session,
            plan: plan,
            liveFieldFromSnapshot: context.live.field)
        return true
    }

    private func continuationPlan(
        for context: AcceptanceContext,
        scope: CotypingAcceptScope,
        settings: AppSettings
    ) -> ContinuationPlan? {
        let remaining = context.session.remainingText
        guard !remaining.isEmpty else {
            clearSuggestion()
            return nil
        }
        let baseChunk = acceptanceBaseChunk(
            from: remaining,
            scope: scope,
            settings: settings)
        let acceptedChunk = settings.cotypingAddSpaceAfterAccept
            ? CotypingAcceptanceChunker.acceptanceChunkConsumingTrailingSpace(
                baseChunk,
                remainingText: remaining)
            : baseChunk
        guard !acceptedChunk.isEmpty else { return nil }
        let liveField = context.live.field ?? context.session.field
        let insertionChunk = CotypingAcceptanceChunker.insertionChunk(
            forAcceptedChunk: acceptedChunk,
            precedingText: liveField.precedingText)
        let insertionText = CotypingAcceptanceChunker.insertionTextApplyingAutoSpace(
            insertionChunk: insertionChunk,
            acceptedChunk: acceptedChunk,
            session: context.session,
            addSpaceAfterAccept: settings.cotypingAddSpaceAfterAccept)
        let forwardDeleteCount = CotypingMidWord.shouldForceContinuation(
            precedingText: liveField.precedingText,
            trailingText: liveField.trailingText)
            ? CotypingMidWord.acceptedTrailingOverlapCount(
                acceptedText: insertionText,
                trailingText: liveField.trailingText)
            : 0
        return .init(
            acceptedChunk: acceptedChunk,
            liveField: liveField,
            insertionText: insertionText,
            forwardDeleteCount: forwardDeleteCount)
    }

    private func acceptanceBaseChunk(
        from remaining: String,
        scope: CotypingAcceptScope,
        settings: AppSettings
    ) -> String {
        guard scope == .chunk else { return remaining }
        return switch settings.cotypingAcceptGranularity {
        case .word:
            CotypingAcceptanceChunker.nextWord(
                in: remaining,
                autoAcceptTrailingPunctuation: settings.cotypingAutoAcceptTrailingPunctuation)
        case .phrase:
            CotypingAcceptanceChunker.nextPhrase(
                in: remaining,
                autoAcceptTrailingPunctuation: settings.cotypingAutoAcceptTrailingPunctuation)
        }
    }

    private func insert(_ plan: ContinuationPlan) -> Bool {
        guard !plan.insertionText.isEmpty else { return true }
        if plan.forwardDeleteCount > 0 {
            return CotypingSyntheticEditPolicy.allowsForwardDeletion(plan.forwardDeleteCount)
                && inserter.replaceForward(
                    deletingCharacters: plan.forwardDeleteCount,
                    with: plan.insertionText)
        }
        // The consuming event tap must remain constant-time and must never
        // touch the pasteboard or walk an app's AX menu tree.
        return inserter.insert(plan.insertionText)
    }

    private func recordAcceptance(
        _ plan: ContinuationPlan,
        settings: AppSettings
    ) {
        lastAcceptanceAt = Date()
        CotypingStatsStore.shared.recordAccept(charsAccepted: plan.acceptedChunk.count)
        acceptedSuggestionBatch.append(
            field: plan.liveField,
            acceptedText: plan.acceptedChunk,
            learningEnabled: settings.cotypingUseLocalLearning)
        acceptedWordCount += CotypingAcceptanceChunker.acceptedWordCount(
            in: plan.acceptedChunk)
    }

    private func advanceContinuation(
        _ current: CotypingSession,
        plan: ContinuationPlan,
        liveFieldFromSnapshot: CotypingField?
    ) {
        let current = current.advanced(by: plan.acceptedChunk.count)
        session = current

        if current.isExhausted {
            pendingInsertionConsumedCount = nil
            lastAcceptedTail = AcceptedSuggestionTail(
                text: plan.acceptedChunk,
                precedingText: plan.liveField.precedingText)
            clearSuggestion()
            state = .idle
            scheduleGenerationAfterHostPublishDelay(baseline: plan.liveField)
        } else {
            presentRemainingContinuation(
                current,
                plan: plan,
                liveFieldFromSnapshot: liveFieldFromSnapshot)
        }
    }

    private func presentRemainingContinuation(
        _ current: CotypingSession,
        plan: ContinuationPlan,
        liveFieldFromSnapshot: CotypingField?
    ) {
        pendingInsertionConsumedCount = current.consumedCount
        let remainingText = current.remainingText
        if !overlay.advanceInline(
            to: remainingText,
            insertedText: plan.insertionText,
            isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(
                plan.liveField.precedingText)) {
            showOverlay(text: remainingText, field: liveFieldFromSnapshot ?? current.field)
        }
        syncAcceptInterception()
        scheduleInlineReanchor(remainingText: remainingText)
    }

    private func scheduleInlineReanchor(remainingText: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self, self.overlay.isVisible, let liveSession = self.session,
                  liveSession.remainingText == remainingText,
                  !self.isAwaitingPostInsertionSync else { return }
            guard let field = await self.focusTracker.refreshNow().field else { return }
            let placement = self.placement(for: field)
            guard !self.overlay.shouldHoldInlineReanchor(
                text: remainingText,
                caretRect: field.caretRect,
                style: field.fieldStyle,
                placement: placement,
                millisecondsSinceLastAcceptance: self.millisecondsSinceLastAcceptance(),
                inputFrameRect: field.inputFrameRect,
                isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(
                    field.precedingText)) else { return }
            self.showOverlay(text: remainingText, field: field, placement: placement)
            self.syncAcceptInterception()
        }
    }

    private func rejectStaleAcceptance(resetState: Bool = false) {
        clearSuggestion()
        if resetState { state = .idle }
    }

    /// Atomically presents a suggestion. The invariant *session exists ⟺
    /// overlay visible ⟺ state == .ready ⟺ accept tap armed* is established
    /// here (and torn down in `clearSuggestion`) — never by hand at call sites.
    func present(
        _ newSession: CotypingSession,
        overlayText: String,
        acceptanceText: String? = nil,
        streamedWork: UInt64? = nil
    ) {
        startSession(newSession, streamedWork: streamedWork)
        showOverlay(text: overlayText, field: newSession.field, acceptanceText: acceptanceText)
        markReady(acceptanceText ?? overlayText)
    }

    /// The published tail of `present` — also used by the advance paths, which
    /// keep the existing overlay window and only re-arm interception + state.
    func markReady(_ text: String) {
        syncAcceptInterception()
        state = .ready(text: text)
    }

    private func startSession(_ newSession: CotypingSession, streamedWork: UInt64?) {
        pendingInsertionConsumedCount = nil
        session = newSession
        if let streamedWork {
            streamAcceptanceFence.markPresented(work: streamedWork)
        } else {
            streamAcceptanceFence.reset()
        }
    }

    func clearSuggestion() {
        if let completed = acceptedSuggestionBatch.complete() {
            CotypingStatsStore.shared.suggestionCompleted()
            if let record = completed.learningRecord {
                learningStore.recordCompletedSuggestion(
                    field: record.field,
                    acceptedText: record.acceptedText)
            }
        }
        session = nil
        streamAcceptanceFence.reset()
        pendingInsertionConsumedCount = nil
        overlay.hide()
        pendingStreamPartial = nil
        streamValidationGeneration &+= 1
        streamValidationTask?.cancel()
        streamValidationTask = nil
        syncAcceptInterception()
    }

    private func freezeStreamedSuggestionForAcceptance() {
        guard streamAcceptanceFence.consumeForAcceptance() != nil else { return }
        cancelPendingGenerationWork()
        pendingStreamPartial = nil
        streamValidationGeneration &+= 1
        streamValidationTask?.cancel()
        streamValidationTask = nil
    }

    private func syncAcceptInterception() {
        inputMonitor.setAcceptActive(
            CotypingAcceptanceOwnershipPolicy.shouldOwnAcceptKey(
                overlayIsVisible: overlay.isVisible,
                hasSession: session != nil))
    }

    func millisecondsSinceLastAcceptance() -> Int? {
        lastAcceptanceAt.map { Int(Date().timeIntervalSince($0) * 1000) }
    }

    private var isAwaitingPostInsertionSync: Bool {
        pendingInsertionConsumedCount != nil
    }
}
