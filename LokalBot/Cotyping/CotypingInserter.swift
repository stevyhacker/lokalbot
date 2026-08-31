import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Tags Cotyping's own synthetic keystrokes so the input taps ignore them and
/// never re-observe an insert as user typing. Ported from Cotabby's
/// `InputSuppressionController` (identity field only).
enum CotypingSyntheticMarker {
    /// "Lokal" in ASCII — an arbitrary sentinel on the event's source user data.
    static let userData: Int64 = 0x4C6F_6B61_6C

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: userData)
    }

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == userData
    }
}

final class CotypingInputSuppressionController {
    private var remainingKeyDownSuppressions = 0
    private var suppressionExpiry = Date.distantPast

    nonisolated static let syntheticSuppressionWindowSeconds: TimeInterval = 1.0

    func registerSyntheticInsertion(expectedKeyDownCount: Int, now: Date = Date()) {
        if now > suppressionExpiry {
            remainingKeyDownSuppressions = 0
        }
        remainingKeyDownSuppressions += max(expectedKeyDownCount, 0)
        suppressionExpiry = now.addingTimeInterval(Self.syntheticSuppressionWindowSeconds)
    }

    func consumeIfNeeded(now: Date = Date()) -> Bool {
        guard remainingKeyDownSuppressions > 0 else {
            return false
        }
        guard now <= suppressionExpiry else {
            remainingKeyDownSuppressions = 0
            return false
        }
        remainingKeyDownSuppressions -= 1
        return true
    }

    func markSynthetic(_ event: CGEvent) {
        CotypingSyntheticMarker.mark(event)
    }

    func isSynthetic(_ event: CGEvent) -> Bool {
        CotypingSyntheticMarker.isSynthetic(event)
    }
}

/// Inserts accepted ghost text into the focused host app by synthesizing Unicode
/// keystrokes (Cotabby's approach — AX value-set is silently dropped by Chromium
/// and others). Each event is marked synthetic so the input monitor skips it.
@MainActor
final class CotypingInserter {
    /// Pending restore of the user's clipboard after a paste insert, so overlapping
    /// pastes coalesce onto the single saved clipboard rather than re-snapshotting
    /// our own completion back into it.
    private var pendingPasteboardRestore: DispatchWorkItem?
    private var savedClipboardForRestore: [[NSPasteboard.PasteboardType: Data]]?
    private var cachedPasteMenuItems: [pid_t: AXUIElement] = [:]
    private let suppressionController: CotypingInputSuppressionController

    init(suppressionController: CotypingInputSuppressionController = CotypingInputSuppressionController()) {
        self.suppressionController = suppressionController
    }

    @discardableResult
    func insert(_ text: String) -> Bool {
        let scrubbed = text.replacingOccurrences(of: "\r", with: "")
        guard !scrubbed.isEmpty,
              let events = Self.unicodeKeyEvents(for: scrubbed) else { return false }
        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: 1)
        post(events)
        return true
    }

    /// Deletes `deletingCharacters` graphemes (one Backspace each) then types
    /// `text`, in one suppressed synthetic burst. Used to swap a typo for its
    /// correction. Backspace is virtual key 51.
    @discardableResult
    func replace(deletingCharacters count: Int, with text: String) -> Bool {
        replace(
            deletingCharacters: count,
            with: text,
            deletionKey: 51,
            deletionAllowed: CotypingSyntheticEditPolicy.allowsBackwardDeletion(count))
    }

    /// Deletes `deletingCharacters` graphemes to the right of the caret (Forward
    /// Delete, virtual key 117) and then types `text`. Used for mid-word accepts
    /// where the model's first characters are already present after the caret.
    @discardableResult
    func replaceForward(deletingCharacters count: Int, with text: String) -> Bool {
        replace(
            deletingCharacters: count,
            with: text,
            deletionKey: 117,
            deletionAllowed: CotypingSyntheticEditPolicy.allowsForwardDeletion(count))
    }

    private func replace(
        deletingCharacters count: Int,
        with text: String,
        deletionKey: CGKeyCode,
        deletionAllowed: Bool
    ) -> Bool {
        let scrubbed = text.replacingOccurrences(of: "\r", with: "")
        guard deletionAllowed, count > 0 || !scrubbed.isEmpty else {
            return false
        }
        var events: [CGEvent] = []
        for _ in 0..<max(0, count) {
            guard let deletionEvents = Self.keyEvents(for: deletionKey) else { return false }
            events.append(contentsOf: deletionEvents)
        }
        if !scrubbed.isEmpty {
            guard let insertionEvents = Self.unicodeKeyEvents(for: scrubbed) else { return false }
            events.append(contentsOf: insertionEvents)
        }
        suppressionController.registerSyntheticInsertion(
            expectedKeyDownCount: max(0, count) + (scrubbed.isEmpty ? 0 : 1))
        post(events)
        return true
    }

    private func post(_ events: [CGEvent]) {
        for event in events { suppressionController.markSynthetic(event) }
        for event in events { event.post(tap: .cghidEventTap) }
    }

    private static func keyEvents(for key: CGKeyCode) -> [CGEvent]? {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else {
            return nil
        }
        return [down, up]
    }

    private static func unicodeKeyEvents(for text: String) -> [CGEvent]? {
        guard let events = keyEvents(for: 0) else { return nil }
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for event in events {
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
        }
        return events
    }

    /// Inserts `text` by placing it on the pasteboard and synthesizing a synthetic
    /// Cmd-V, then restoring the user's clipboard shortly after. A trimmed port of
    /// Cotabby's `insertViaPaste`. Used by dictation commits outside the consuming
    /// cotyping event tap. Returns false on any setup failure (after restoring the
    /// clipboard) so the caller can fall back to keystrokes.
    @discardableResult
    func insertViaPaste(_ text: String) -> Bool {
        let scrubbed = text.replacingOccurrences(of: "\r", with: "")
        guard !scrubbed.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        if pendingPasteboardRestore == nil {
            savedClipboardForRestore = Self.snapshotPasteboard(pasteboard)
        }
        let saved = savedClipboardForRestore ?? []

        pasteboard.clearContents()
        guard pasteboard.setString(scrubbed, forType: .string) else {
            pendingPasteboardRestore?.cancel()
            Self.restorePasteboard(saved, to: pasteboard)
            clearPendingPasteboardRestore()
            return false
        }
        let expectedChangeCount = pasteboard.changeCount

        if pressPasteMenuItem() {
            schedulePasteboardRestore(saved: saved, expectedChangeCount: expectedChangeCount)
            return true
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            pendingPasteboardRestore?.cancel()
            Self.restorePasteboard(saved, to: pasteboard)
            clearPendingPasteboardRestore()
            return false
        }
        // Cmd via flags (no separate modifier key event). Marked synthetic so the
        // consuming input tap ignores it.
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: 1)
        suppressionController.markSynthetic(vDown)
        suppressionController.markSynthetic(vUp)
        vDown.post(tap: .cgAnnotatedSessionEventTap)
        vUp.post(tap: .cgAnnotatedSessionEventTap)

        schedulePasteboardRestore(saved: saved, expectedChangeCount: expectedChangeCount)
        return true
    }

    private func pressPasteMenuItem() -> Bool {
        guard let focusedElement = CotypingAXHelper.focusedElement(),
              let application = CotypingAXHelper.owningApplication(of: focusedElement) else {
            return false
        }
        let pid = application.processIdentifier
        if let cached = cachedPasteMenuItems[pid] {
            if AXUIElementPerformAction(cached, kAXPressAction as CFString) == .success {
                return true
            }
            cachedPasteMenuItems[pid] = nil
        }
        guard let item = CotypingAXHelper.pasteMenuItem(forApplicationPID: pid),
              AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            return false
        }
        cachedPasteMenuItems[pid] = item
        return true
    }

    private func schedulePasteboardRestore(
        saved: [[NSPasteboard.PasteboardType: Data]],
        expectedChangeCount: Int
    ) {
        let restore = DispatchWorkItem { [weak self] in
            if NSPasteboard.general.changeCount == expectedChangeCount {
                Self.restorePasteboard(saved, to: NSPasteboard.general)
            }
            self?.clearPendingPasteboardRestore()
        }
        pendingPasteboardRestore?.cancel()
        pendingPasteboardRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteboardRestoreDelay, execute: restore)
    }

    /// How long the completion stays on the pasteboard before the user's clipboard
    /// is restored — long enough for the host to service Cmd-V, short enough that
    /// the user's clipboard is theirs again almost immediately.
    private static let pasteboardRestoreDelay: TimeInterval = 0.3

    private func clearPendingPasteboardRestore() {
        pendingPasteboardRestore = nil
        savedClipboardForRestore = nil
    }

    /// Captures every representation of every pasteboard item so the user's
    /// clipboard can be restored exactly, not just its plain-text form.
    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var reps: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { reps[type] = data }
            }
            return reps
        }
    }

    private static func restorePasteboard(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
