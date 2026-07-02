import Foundation

/// Pure session-vs-live-field reconciliation: is the live field still the one
/// a session/generation was built against, did the host publish typing that
/// advances the session, and when should the coordinator wait for a slow host
/// to publish an insertion instead of tearing the session down. All functions
/// are pure over value types; the coordinator supplies the live state.
enum CotypingSessionReconciler {

    /// True when the host published a field state different from `baseline` —
    /// the signal that a keystroke landed and generation may proceed.
    static func hostPublishDidMove(from baseline: CotypingField?, to current: CotypingField?) -> Bool {
        guard let baseline else { return current != nil }
        guard let current else { return true }
        return current.contentSignature != baseline.contentSignature
            || current.processID != baseline.processID
            || current.bundleID != baseline.bundleID
            || current.role != baseline.role
            || knownFocusIdentityDidMove(from: baseline, to: current)
            || CotypingFieldIdentity.suggestionAnchor(for: current)
                != CotypingFieldIdentity.suggestionAnchor(for: baseline)
    }

    /// True when `liveField` is plausibly the same editable field `session` was
    /// generated against: same process/role, compatible focused-field identity
    /// when AX exposes one, and live text still anchored to the session prefix
    /// (which only grows as we accept words). Guards against accepting a stale
    /// suggestion after focus moved to another field in the same app, where the
    /// PID alone would still match.
    static func isContinuation(of session: CotypingSession, liveField: CotypingField?) -> Bool {
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
        let windowLimit = CotypingAXHelper.maxPrecedingCharacters
        guard previous.count >= windowLimit || live.count >= windowLimit else {
            return false
        }
        return hasCappedPrefixWindowOverlap(previous: previous, live: live)
    }

    static func isAcceptanceContinuation(
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

    static func shouldClearActiveSessionOnFocusChange(
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

    static func isCurrentGenerationTarget(
        _ originalField: CotypingField,
        liveField: CotypingField?
    ) -> Bool {
        guard let liveField else { return false }
        guard liveField.processID == originalField.processID,
              liveField.bundleID == originalField.bundleID,
              liveField.role == originalField.role,
              liveField.contentSignature == originalField.contentSignature,
              CotypingFieldIdentity.suggestionAnchor(for: liveField)
                == CotypingFieldIdentity.suggestionAnchor(for: originalField) else {
            return false
        }
        if let originalIdentity = originalField.focusIdentityKey,
           let liveIdentity = liveField.focusIdentityKey,
           originalIdentity != liveIdentity {
            return false
        }
        return true
    }

    /// Rebases a continuation session onto the host-published field. Handles
    /// both plain typing that matches the suggestion tail (advancing the
    /// consumed prefix) and the host catching up to an already-optimistically-
    /// advanced session (typed is empty).
    static func sessionReconciledByPublishedTyping(
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

    static func shouldAwaitPostInsertionSync(
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

    static func sessionAdvancedByTypedCharacters(
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

    /// A regenerated suggestion that merely re-suggests the chunk the user just
    /// accepted (host hasn't published the insert yet) must not be shown.
    static func isStaleAcceptanceEcho(
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

    /// The field snapshot as it will look once the host publishes an accepted
    /// insertion — the target for speculative post-acceptance generation.
    static func optimisticFieldAfterAcceptance(
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

    // MARK: - Private

    private static func knownFocusIdentityDidMove(
        from baseline: CotypingField,
        to current: CotypingField
    ) -> Bool {
        guard let original = baseline.focusIdentityKey,
              let live = current.focusIdentityKey else {
            return false
        }
        return original != live
    }

    private static func isPostInsertionSyncTarget(
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

    private static func hasCappedPrefixWindowOverlap(previous: String, live: String) -> Bool {
        let windowLimit = CotypingAXHelper.maxPrecedingCharacters
        let maxLength = min(min(previous.count, live.count), windowLimit)
        let minimumOverlap = min(1024, maxLength)
        guard minimumOverlap > 0 else { return false }
        var length = maxLength
        while length >= minimumOverlap {
            if previous.suffix(length) == live.prefix(length) { return true }
            length -= 1
        }
        return false
    }
}
