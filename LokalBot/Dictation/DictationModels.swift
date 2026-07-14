import CoreGraphics
import Foundation

enum DictationTriggerMode: String, Codable, CaseIterable, Identifiable {
    case pushToTalk = "Push to talk"
    case toggle = "Toggle"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pushToTalk: "Push to talk"
        case .toggle: "Toggle"
        }
    }
}

enum DictationOutputMode: String, Codable, CaseIterable, Identifiable {
    case pasteIntoFocusedApp = "Paste into focused app"
    case copyToClipboard = "Copy to clipboard"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pasteIntoFocusedApp: "Paste into focused app"
        case .copyToClipboard: "Copy to clipboard"
        }
    }
}

struct DictationLiveTranscript: Equatable, Sendable {
    var committed: String = ""
    var tentative: String = ""

    var isEmpty: Bool {
        committed.isEmpty && tentative.isEmpty
    }

    var displayText: String {
        [committed, tentative]
            .filter { !$0.isEmpty }
            .joined(separator: committed.isEmpty || tentative.isEmpty ? "" : " ")
    }

    static func preview(from text: String) -> Self {
        let normalized = Transcript.normalizedText(text)
        guard !normalized.isEmpty else { return .init() }

        if let last = normalized.last, ".!?".contains(last) {
            return .init(committed: normalized, tentative: "")
        }

        if let boundary = lastSentenceBoundary(in: normalized) {
            let committed = normalized[..<normalized.index(after: boundary)]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tentative = normalized[normalized.index(after: boundary)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(committed: committed, tentative: tentative)
        }

        let words = normalized.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > 8 else {
            return .init(committed: "", tentative: normalized)
        }
        let committed = words.dropLast(6).joined(separator: " ")
        let tentative = words.suffix(6).joined(separator: " ")
        return .init(committed: committed, tentative: tentative)
    }

    private static func lastSentenceBoundary(in text: String) -> String.Index? {
        text.indices
            .filter { ".!?".contains(text[$0]) }
            .last
    }
}

/// The app/field that owned focus when dictation began. Final transcription
/// may take long enough for focus to move; insertion is allowed only when the
/// same destination still owns focus, otherwise the text is copied safely.
struct DictationDeliveryTarget: Equatable, Sendable {
    let processID: pid_t
    let bundleID: String?
    let focusIdentityKey: String?

    func matches(processID currentProcessID: pid_t,
                 bundleID currentBundleID: String?,
                 focusIdentityKey currentFocusIdentityKey: String?) -> Bool {
        guard processID == currentProcessID else { return false }
        if let bundleID, let currentBundleID, bundleID != currentBundleID { return false }
        if let focusIdentityKey, !focusIdentityKey.isEmpty {
            return focusIdentityKey == currentFocusIdentityKey
        }
        return true
    }

    /// A blocked snapshot always wins over the app-only fallback. In
    /// particular, a target captured before AX exposed a field must never
    /// become permission to paste into a same-app password field later.
    func matches(_ snapshot: DictationFocusSnapshot) -> Bool {
        guard !snapshot.isSecureOrBlocked else { return false }
        return matches(
            processID: snapshot.processID,
            bundleID: snapshot.bundleID,
            focusIdentityKey: snapshot.focusIdentityKey)
    }

    static func captured(from snapshot: DictationFocusSnapshot) -> Self? {
        guard !snapshot.isSecureOrBlocked else { return nil }
        return Self(
            processID: snapshot.processID,
            bundleID: snapshot.bundleID,
            focusIdentityKey: snapshot.focusIdentityKey)
    }
}

/// The minimum Accessibility state needed to bind and later validate a
/// dictation destination. It intentionally carries no field text or geometry.
struct DictationFocusSnapshot: Equatable, Sendable {
    let processID: pid_t
    let bundleID: String?
    let focusIdentityKey: String?
    let isSecureOrBlocked: Bool
}

struct DictationFocusCaptureResult: Equatable, Sendable {
    let snapshot: DictationFocusSnapshot?
    let timedOut: Bool

    static let timeout = Self(snapshot: nil, timedOut: true)
}

/// Serializes lightweight dictation focus reads on a background queue and
/// gives every caller one wall-clock deadline. A wedged target app therefore
/// fails closed without blocking the main actor or accumulating AX workers.
final class DictationFocusSnapshotExecutor: @unchecked Sendable {
    typealias Resolver = @Sendable () -> DictationFocusSnapshot?

    static let shared = DictationFocusSnapshotExecutor()
    static let defaultDeadlineMilliseconds = 120

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<DictationFocusCaptureResult, Never>
    }

    private struct Batch {
        let id: UInt64
        var waiters: [UInt64: Waiter]
    }

    private let stateQueue = DispatchQueue(label: "me.dotenv.LokalBot.dictation.ax-snapshot-state")
    private let workerQueue = DispatchQueue(
        label: "me.dotenv.LokalBot.dictation.ax-snapshot-worker",
        qos: .userInitiated)
    private let deadlineMilliseconds: Int
    private let resolver: Resolver
    private var nextIdentifier: UInt64 = 0
    private var active: Batch?
    private var pending: Batch?

    init(
        deadlineMilliseconds: Int = defaultDeadlineMilliseconds,
        resolver: @escaping Resolver = { CotypingAXHelper.resolveDictationFocusSnapshot() }
    ) {
        self.deadlineMilliseconds = max(1, deadlineMilliseconds)
        self.resolver = resolver
    }

    func capture() async -> DictationFocusCaptureResult {
        await withCheckedContinuation { continuation in
            stateQueue.async { [self] in
                nextIdentifier &+= 1
                let waiterID = nextIdentifier
                let waiter = Waiter(id: waiterID, continuation: continuation)
                enqueue(waiter)
                stateQueue.asyncAfter(
                    deadline: .now() + .milliseconds(deadlineMilliseconds)
                ) { [weak self] in
                    self?.expire(waiterID: waiterID)
                }
            }
        }
    }

    private func enqueue(_ waiter: Waiter) {
        guard active != nil else {
            nextIdentifier &+= 1
            start(Batch(id: nextIdentifier, waiters: [waiter.id: waiter]))
            return
        }
        if var pending {
            pending.waiters[waiter.id] = waiter
            self.pending = pending
        } else {
            nextIdentifier &+= 1
            pending = Batch(id: nextIdentifier, waiters: [waiter.id: waiter])
        }
    }

    private func start(_ batch: Batch) {
        active = batch
        let batchID = batch.id
        workerQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = resolver()
            stateQueue.async { [weak self] in
                self?.finish(batchID: batchID, snapshot: snapshot)
            }
        }
    }

    private func finish(batchID: UInt64, snapshot: DictationFocusSnapshot?) {
        guard let completed = active, completed.id == batchID else { return }
        active = nil
        let result = DictationFocusCaptureResult(snapshot: snapshot, timedOut: false)
        for waiter in completed.waiters.values {
            waiter.continuation.resume(returning: result)
        }
        startPendingIfNeeded()
    }

    private func expire(waiterID: UInt64) {
        if var active, let waiter = active.waiters.removeValue(forKey: waiterID) {
            self.active = active
            waiter.continuation.resume(returning: .timeout)
            return
        }
        if var pending, let waiter = pending.waiters.removeValue(forKey: waiterID) {
            self.pending = pending.waiters.isEmpty ? nil : pending
            waiter.continuation.resume(returning: .timeout)
        }
    }

    private func startPendingIfNeeded() {
        guard active == nil, let pending else { return }
        self.pending = nil
        guard !pending.waiters.isEmpty else { return }
        start(pending)
    }
}

struct DictationPreviewAudioRange: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
}

/// Pure planning for the rolling dictation preview. Each pass starts slightly
/// before the last completed pass so the ASR model hears enough context to
/// finish a word that crossed the boundary, without decoding the whole growing
/// recording again.
enum DictationPreviewWindowPlanner {
    static let defaultOverlapSeconds: TimeInterval = 2.5

    static func range(previousEnd: TimeInterval,
                      currentEnd: TimeInterval) -> DictationPreviewAudioRange? {
        range(previousEnd: previousEnd,
              currentEnd: currentEnd,
              overlapSeconds: defaultOverlapSeconds)
    }

    static func range(previousEnd: TimeInterval,
                      currentEnd: TimeInterval,
                      overlapSeconds: TimeInterval) -> DictationPreviewAudioRange? {
        let previous = max(0, previousEnd)
        guard currentEnd > previous else { return nil }
        return .init(
            start: max(0, previous - max(0, overlapSeconds)),
            end: currentEnd
        )
    }
}

/// Deterministically joins overlapping ASR windows. The newest window replaces
/// the matched suffix so revised capitalization or punctuation at the boundary
/// wins, while a window with no trustworthy two-word overlap is appended rather
/// than risking the loss of already-visible speech.
enum DictationPreviewTextStitcher {
    static func stitch(previous: String,
                       incoming: String,
                       maximumOverlapWords: Int = 32,
                       minimumOverlapWords: Int = 2) -> String {
        let oldText = Transcript.normalizedText(previous)
        let newText = Transcript.normalizedText(incoming)
        guard !oldText.isEmpty else { return newText }
        guard !newText.isEmpty else { return oldText }

        let oldWords = oldText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let newWords = newText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let upperBound = min(max(0, maximumOverlapWords), oldWords.count, newWords.count)
        let lowerBound = max(1, minimumOverlapWords)

        if upperBound >= lowerBound {
            for count in stride(from: upperBound, through: lowerBound, by: -1) {
                let oldStart = oldWords.count - count
                let matches = (0..<count).allSatisfy { offset in
                    wordKey(oldWords[oldStart + offset]) == wordKey(newWords[offset])
                        && !wordKey(newWords[offset]).isEmpty
                }
                if matches {
                    return (oldWords.dropLast(count) + newWords).joined(separator: " ")
                }
            }
        }

        return oldText + " " + newText
    }

    private static func wordKey(_ word: String) -> String {
        word
            .folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

struct DictationShortcut: Equatable, Sendable {
    var keyCode: CGKeyCode
    var modifiers: CGEventFlags

    static let handyDefault = DictationShortcut(keyCode: 49, modifiers: .maskAlternate)
    static let label = "⌥ Space"

    func matches(_ event: CGEvent) -> Bool {
        matchesKeyCode(event) && event.flags.dictationRelevantModifiers == modifiers
    }

    func matchesKeyCode(_ event: CGEvent) -> Bool {
        CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == keyCode
    }
}

private extension CGEventFlags {
    var dictationRelevantModifiers: CGEventFlags {
        intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
    }
}
