import Foundation

/// Acceptance, session presentation, insertion bookkeeping, and teardown.
extension CotypingCoordinator {
    // MARK: - Acceptance (called synchronously from the accept tap)

    func acceptFromTap(_ scope: CotypingAcceptScope) -> Bool {
        guard isRunning else { return false }
        guard CotypingAcceptanceOwnershipPolicy.shouldOwnAcceptKey(
                  overlayIsVisible: overlay.isVisible,
                  hasSession: session != nil),
              var current = session else { return false }
        // The visible ghost must match the session tail — a mismatch means the
        // overlay is showing stale text and accepting would insert the wrong thing.
        guard overlay.acceptanceText == current.remainingText else {
            clearSuggestion()
            state = .idle
            return false
        }
        freezeStreamedSuggestionForAcceptance()
        let live = CotypingAXHelper.resolveAcceptanceSnapshot(
            cachedField: focusTracker.focus.field)
        guard CotypingAcceptanceSnapshotPolicy.canAccept(
            markedTextState: live.markedTextState,
            composingInputModeActive: inputSourceMonitor.isComposingIMEActive,
            hasLiveContent: live.hasLiveContent,
            selectionLength: live.field?.selectionLength) else {
            clearSuggestion()
            state = .idle
            return false
        }

        // Replacements delete existing host text, so they share one exact-field
        // and exact-trigger validation path. A same-PID match is not sufficient.
        if case .continuation = current.kind {
            // Continue through the normal append-only acceptance path below.
        } else {
            guard let plan = CotypingReplacementAcceptancePlanner.plan(
                for: current,
                liveField: live.field),
                  inserter.replace(
                      deletingCharacters: plan.deletingCharacters,
                      with: plan.replacementText) else {
                clearSuggestion()
                return false
            }
            if case .correction = current.kind { acceptedWordCount += 1 }
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
        let inserted: Bool
        if insertionText.isEmpty {
            inserted = true
        } else if forwardDeleteCount > 0 {
            inserted = CotypingSyntheticEditPolicy.allowsForwardDeletion(forwardDeleteCount)
                && inserter.replaceForward(
                    deletingCharacters: forwardDeleteCount,
                    with: insertionText)
        } else {
            // The consuming event tap must remain constant-time and must never
            // touch the pasteboard or walk an app's AX menu tree. Composing
            // input sources fail open above; direct-input continuations use one
            // synthetic Unicode event pair regardless of text length or lines.
            inserted = inserter.insert(insertionText)
        }
        guard inserted else {
            clearSuggestion()
            state = .idle
            return false
        }
        lastAcceptanceAt = Date()
        CotypingStatsStore.shared.recordAccept(charsAccepted: acceptedChunk.count)
        acceptedSuggestionBatch.append(
            field: liveField,
            acceptedText: acceptedChunk,
            learningEnabled: settings.cotypingUseLocalLearning)

        acceptedWordCount += CotypingAcceptanceChunker.acceptedWordCount(in: acceptedChunk)
        current = current.advanced(by: acceptedChunk.count)
        session = current

        if current.isExhausted {
            pendingInsertionConsumedCount = nil
            lastAcceptedTail = AcceptedSuggestionTail(text: acceptedChunk, precedingText: liveField.precedingText)
            clearSuggestion()
            state = .idle
            scheduleGenerationAfterHostPublishDelay(baseline: liveField)
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
                let focus = await self.focusTracker.refreshNow()
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
        lastSuggestion = text
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

    /// Clears both persisted examples and any accepted text still waiting for
    /// the current suggestion to close, so deletion cannot be undone by a
    /// later `clearSuggestion()` flush.
    func clearLearnedWritingData() {
        acceptedSuggestionBatch.discardLearningRecord()
        learningStore.clear()
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
