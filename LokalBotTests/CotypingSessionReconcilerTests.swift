import AppKit
import XCTest
@testable import LokalBot

// MARK: - Stale-field guard (continuation)

final class CotypingContinuationTests: XCTestCase {
    private func field(
        _ preceding: String,
        trailingText: String = "",
        pid: pid_t = 5,
        focusIdentityKey: String? = nil
    ) -> CotypingField {
        CotypingField(
            appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", processID: pid,
            role: "AXTextArea", focusIdentityKey: focusIdentityKey,
            precedingText: preceding, trailingText: trailingText,
            selectionLength: 0, caretRect: .zero, isSecure: false, caretIsExact: true)
    }

    private func session(
        _ preceding: String,
        pid: pid_t = 5,
        focusIdentityKey: String? = nil
    ) -> CotypingSession {
        CotypingSession(
            field: field(preceding, pid: pid, focusIdentityKey: focusIdentityKey),
            fullText: " up on the deck")
    }

    func testSameUntouchedFieldIsContinuation() {
        XCTAssertTrue(CotypingSessionReconciler.isContinuation(of: session("I wanted to follow"), liveField: field("I wanted to follow")))
    }

    func testFieldGrownByAcceptedWordsIsContinuation() {
        // After accepting a word, the live preceding text only grows.
        XCTAssertTrue(CotypingSessionReconciler.isContinuation(of: session("I wanted to follow"), liveField: field("I wanted to follow up")))
    }

    func testDifferentFieldSameProcessIsNotContinuation() {
        // Another compose box in the same app (same PID) must NOT match.
        XCTAssertFalse(CotypingSessionReconciler.isContinuation(of: session("I wanted to follow"), liveField: field("Reply to the thread")))
    }

    func testDifferentFieldSameProcessWithSameTextIsNotContinuationWhenIdentityDiffers() {
        XCTAssertFalse(CotypingSessionReconciler.isContinuation(
            of: session("I wanted to follow", focusIdentityKey: "field-a"),
            liveField: field("I wanted to follow", focusIdentityKey: "field-b")))
    }

    func testMissingFocusIdentityKeepsTextFallbackForContinuation() {
        XCTAssertTrue(CotypingSessionReconciler.isContinuation(
            of: session("I wanted to follow", focusIdentityKey: "field-a"),
            liveField: field("I wanted to follow")))
    }

    func testCappedLongFieldShiftAfterAcceptedWordIsContinuation() {
        let previous = String(repeating: "a", count: 4096)
        let live = String(previous.dropFirst(3)) + " up"
        XCTAssertTrue(CotypingSessionReconciler.isContinuation(of: session(previous), liveField: field(live)))
    }

    func testDifferentProcessIsNotContinuation() {
        XCTAssertFalse(CotypingSessionReconciler.isContinuation(of: session("I wanted to follow", pid: 5), liveField: field("I wanted to follow", pid: 99)))
    }

    func testNoLiveFieldIsNotContinuation() {
        XCTAssertFalse(CotypingSessionReconciler.isContinuation(of: session("I wanted to follow"), liveField: nil))
    }

    func testAcceptanceRequiresTrailingTextToRemainStable() {
        let current = CotypingSession(
            field: field("I wanted to follow", trailingText: " tomorrow"),
            fullText: " up on the deck")

        XCTAssertTrue(CotypingSessionReconciler.isAcceptanceContinuation(
            of: current,
            liveField: field("I wanted to follow", trailingText: " tomorrow"),
            pendingInsertionConsumedCount: nil))
        XCTAssertFalse(CotypingSessionReconciler.isAcceptanceContinuation(
            of: current,
            liveField: field("I wanted to follow", trailingText: " changed"),
            pendingInsertionConsumedCount: nil))
    }

    func testFocusChangeClearsWhenTrailingTextChangesOutsideInsertionSync() {
        let current = CotypingSession(
            field: field("I wanted to follow", trailingText: " tomorrow"),
            fullText: " up on the deck")

        XCTAssertTrue(CotypingSessionReconciler.shouldClearActiveSessionOnFocusChange(
            current,
            liveField: field("I wanted to follow", trailingText: " changed"),
            pendingInsertionConsumedCount: nil))
    }

    func testPostInsertionSyncToleratesTransientTrailingAndPrefixRaces() {
        let current = session("I wanted to follow").advanced(by: 3)

        XCTAssertFalse(CotypingSessionReconciler.shouldClearActiveSessionOnFocusChange(
            current,
            liveField: field("I wanted to follow", trailingText: " changed"),
            pendingInsertionConsumedCount: 3))
        XCTAssertFalse(CotypingSessionReconciler.shouldClearActiveSessionOnFocusChange(
            current,
            liveField: field("Goodbye", trailingText: " changed"),
            pendingInsertionConsumedCount: 3))
    }

    func testCurrentGenerationTargetRequiresSameContentAndIdentity() {
        var original = field("I wanted to follow")
        original.focusIdentityKey = "field-a"
        var live = original

        XCTAssertTrue(CotypingSessionReconciler.isCurrentGenerationTarget(original, liveField: live))

        live.precedingText += " up"
        XCTAssertFalse(CotypingSessionReconciler.isCurrentGenerationTarget(original, liveField: live))

        live = original
        live.focusIdentityKey = "field-b"
        XCTAssertFalse(CotypingSessionReconciler.isCurrentGenerationTarget(original, liveField: live))
    }

    func testCurrentGenerationTargetAllowsMissingFocusIdentityButStillRequiresAnchorIdentity() {
        var original = field("I wanted to follow")
        original.windowTitle = "Draft"
        var live = original
        live.focusIdentityKey = nil

        XCTAssertTrue(CotypingSessionReconciler.isCurrentGenerationTarget(original, liveField: live))

        live.windowTitle = "Other Draft"
        XCTAssertFalse(CotypingSessionReconciler.isCurrentGenerationTarget(original, liveField: live))
    }

    func testHostPublishDetectsSameTextFieldSwitchWhenIdentityIsKnown() {
        let original = field("I wanted to follow", focusIdentityKey: "field-a")
        let live = field("I wanted to follow", focusIdentityKey: "field-b")

        XCTAssertTrue(CotypingSessionReconciler.hostPublishDidMove(from: original, to: live))
    }

    func testHostPublishUsesAnchorIdentityWhenFocusIdentityIsMissing() {
        var original = field("I wanted to follow")
        original.windowTitle = "Draft"
        var live = original
        live.windowTitle = "Other Draft"

        XCTAssertTrue(CotypingSessionReconciler.hostPublishDidMove(from: original, to: live))
    }

    func testHostPublishKeepsSameTextFallbackWhenIdentityIsMissing() {
        let original = field("I wanted to follow", focusIdentityKey: "field-a")
        let live = field("I wanted to follow")

        XCTAssertFalse(CotypingSessionReconciler.hostPublishDidMove(from: original, to: live))
    }

    func testPublishedTypingAdvancesSuggestionTail() throws {
        let advanced = try XCTUnwrap(CotypingSessionReconciler.sessionReconciledByPublishedTyping(
            session("I wanted to follow"),
            liveField: field("I wanted to follow up")))

        XCTAssertEqual(advanced.consumedCount, 3)
        XCTAssertEqual(advanced.remainingText, " on the deck")
        XCTAssertEqual(advanced.field.precedingText, "I wanted to follow up")
    }

    func testPublishedTypingHonorsAlreadyAcceptedPrefix() throws {
        let accepted = session("I wanted to follow").advanced(by: 3)
        let advanced = try XCTUnwrap(CotypingSessionReconciler.sessionReconciledByPublishedTyping(
            accepted,
            liveField: field("I wanted to follow up on")))

        XCTAssertEqual(advanced.consumedCount, 6)
        XCTAssertEqual(advanced.remainingText, " the deck")
    }

    func testPublishedTypingDoesNotAdvanceMismatchedText() {
        XCTAssertNil(CotypingSessionReconciler.sessionReconciledByPublishedTyping(
            session("I wanted to follow"),
            liveField: field("I wanted to follow nope")))
    }

    func testPublishedTypingDoesNotAdvanceAcrossKnownDifferentFieldIdentity() {
        XCTAssertNil(CotypingSessionReconciler.sessionReconciledByPublishedTyping(
            session("I wanted to follow", focusIdentityKey: "field-a"),
            liveField: field("I wanted to follow up", focusIdentityKey: "field-b")))
    }

    func testDirectTypedCharactersAdvanceSuggestionTailBeforeHostPublishes() throws {
        let advanced = try XCTUnwrap(CotypingSessionReconciler.sessionAdvancedByTypedCharacters(
            session("I wanted to follow"),
            typedCharacters: " up"))

        XCTAssertEqual(advanced.consumedCount, 3)
        XCTAssertEqual(advanced.remainingText, " on the deck")
        XCTAssertEqual(advanced.field.precedingText, "I wanted to follow")
    }

    func testDirectTypedCharactersRejectMismatchAndControlInput() {
        XCTAssertNil(CotypingSessionReconciler.sessionAdvancedByTypedCharacters(
            session("I wanted to follow"),
            typedCharacters: " nope"))
        XCTAssertNil(CotypingSessionReconciler.sessionAdvancedByTypedCharacters(
            session("I wanted to follow"),
            typedCharacters: "\n"))
    }

    func testPublishedTypingRebasesOptimisticallyAdvancedSessionWhenHostCatchesUp() throws {
        let optimistic = session("I wanted to follow").advanced(by: 3)
        let rebased = try XCTUnwrap(CotypingSessionReconciler.sessionReconciledByPublishedTyping(
            optimistic,
            liveField: field("I wanted to follow up")))

        XCTAssertEqual(rebased.consumedCount, 3)
        XCTAssertEqual(rebased.remainingText, " on the deck")
        XCTAssertEqual(rebased.field.precedingText, "I wanted to follow up")
    }

    func testPublishedTypingCanAdvanceBeyondOptimisticConsumedPrefix() throws {
        let optimistic = session("I wanted to follow").advanced(by: 1)
        let advanced = try XCTUnwrap(CotypingSessionReconciler.sessionReconciledByPublishedTyping(
            optimistic,
            liveField: field("I wanted to follow up")))

        XCTAssertEqual(advanced.consumedCount, 3)
        XCTAssertEqual(advanced.remainingText, " on the deck")
    }

    func testPostInsertionSyncWaitsWhileAcceptedTextIsNotPublished() {
        let accepted = session("I wanted to follow").advanced(by: 3)

        XCTAssertTrue(CotypingSessionReconciler.shouldAwaitPostInsertionSync(
            accepted,
            liveField: field("I wanted to follow"),
            pendingInsertionConsumedCount: 3))
    }

    func testPostInsertionSyncStopsWaitingOnceAcceptedTextPublishes() {
        let accepted = session("I wanted to follow").advanced(by: 3)

        XCTAssertFalse(CotypingSessionReconciler.shouldAwaitPostInsertionSync(
            accepted,
            liveField: field("I wanted to follow up"),
            pendingInsertionConsumedCount: 3))
    }

    func testPostInsertionSyncRequiresMatchingPendingConsumedCount() {
        let accepted = session("I wanted to follow").advanced(by: 3)

        XCTAssertFalse(CotypingSessionReconciler.shouldAwaitPostInsertionSync(
            accepted,
            liveField: field("I wanted to follow"),
            pendingInsertionConsumedCount: nil))
        XCTAssertFalse(CotypingSessionReconciler.shouldAwaitPostInsertionSync(
            accepted,
            liveField: field("I wanted to follow"),
            pendingInsertionConsumedCount: 1))
    }

    func testPostInsertionSyncDoesNotCrossKnownDifferentFieldIdentity() {
        let accepted = session("I wanted to follow", focusIdentityKey: "field-a").advanced(by: 3)

        XCTAssertFalse(CotypingSessionReconciler.shouldAwaitPostInsertionSync(
            accepted,
            liveField: field("I wanted to follow", focusIdentityKey: "field-b"),
            pendingInsertionConsumedCount: 3))
    }

    func testPostInsertionSyncDoesNotWaitWhenTextIsSelected() {
        let accepted = session("I wanted to follow").advanced(by: 3)
        var selected = field("I wanted to follow")
        selected.selectionLength = 2

        XCTAssertFalse(CotypingSessionReconciler.shouldAwaitPostInsertionSync(
            accepted,
            liveField: selected,
            pendingInsertionConsumedCount: 3))
    }

    func testPostInsertionSyncToleratesPrefixAnchorRace() {
        let accepted = session("I wanted to follow").advanced(by: 3)

        XCTAssertTrue(CotypingSessionReconciler.shouldAwaitPostInsertionSync(
            accepted,
            liveField: field("Goodbye"),
            pendingInsertionConsumedCount: 3))
    }

    func testStaleAcceptanceEchoDropsRepeatOfAcceptedTailWhileFieldUnchanged() {
        XCTAssertTrue(CotypingSessionReconciler.isStaleAcceptanceEcho(
            resultText: " today",
            acceptedChunk: " today",
            currentPrecedingText: "what's on your mind",
            acceptedPrecedingText: "what's on your mind"))
    }

    func testStaleAcceptanceEchoToleratesLeadingWhitespaceDifference() {
        XCTAssertTrue(CotypingSessionReconciler.isStaleAcceptanceEcho(
            resultText: "today",
            acceptedChunk: " today",
            currentPrecedingText: "what's on your mind",
            acceptedPrecedingText: "what's on your mind"))
    }

    func testStaleAcceptanceEchoAllowsSuggestionOnceInsertPublished() {
        XCTAssertFalse(CotypingSessionReconciler.isStaleAcceptanceEcho(
            resultText: " today",
            acceptedChunk: " today",
            currentPrecedingText: "what's on your mind today",
            acceptedPrecedingText: "what's on your mind"))
    }

    func testStaleAcceptanceEchoAllowsGenuinelyDifferentContinuation() {
        XCTAssertFalse(CotypingSessionReconciler.isStaleAcceptanceEcho(
            resultText: " tomorrow",
            acceptedChunk: " today",
            currentPrecedingText: "what's on your mind",
            acceptedPrecedingText: "what's on your mind"))
    }

    func testStaleAcceptanceEchoIgnoresWhitespaceOnlyChunk() {
        XCTAssertFalse(CotypingSessionReconciler.isStaleAcceptanceEcho(
            resultText: " ",
            acceptedChunk: " ",
            currentPrecedingText: "what's on your mind",
            acceptedPrecedingText: "what's on your mind"))
    }

    func testOptimisticFieldAfterAcceptanceAppendsInsertedText() {
        let optimistic = CotypingSessionReconciler.optimisticFieldAfterAcceptance(
            field("what's on your mind"),
            insertionText: " today")

        XCTAssertEqual(optimistic.precedingText, "what's on your mind today")
        XCTAssertEqual(optimistic.trailingText, "")
        XCTAssertEqual(optimistic.selectionLength, 0)
    }

    func testOptimisticFieldAfterAcceptanceDropsForwardDeletedTrailingOverlap() {
        var live = field("rec")
        live.trailingText = "eive the files"

        let optimistic = CotypingSessionReconciler.optimisticFieldAfterAcceptance(
            live,
            insertionText: "eive",
            deletingTrailingCharacters: 4)

        XCTAssertEqual(optimistic.precedingText, "receive")
        XCTAssertEqual(optimistic.trailingText, " the files")
    }
}
