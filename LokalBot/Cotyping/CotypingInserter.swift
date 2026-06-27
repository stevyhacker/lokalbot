import AppKit
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

/// Inserts accepted ghost text into the focused host app by synthesizing Unicode
/// keystrokes (Cotabby's approach — AX value-set is silently dropped by Chromium
/// and others). Each event is marked synthetic so the input monitor skips it.
@MainActor
final class CotypingInserter {
    /// Pending restore of the user's clipboard after a paste insert, so overlapping
    /// pastes coalesce onto the single saved clipboard rather than re-snapshotting
    /// our own completion back into it.
    private var pendingPasteboardRestore: DispatchWorkItem?
    @discardableResult
    func insert(_ text: String) -> Bool {
        let scrubbed = text.replacingOccurrences(of: "\r", with: "")
        guard !scrubbed.isEmpty else { return false }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return false
        }
        let utf16 = Array(scrubbed.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
        CotypingSyntheticMarker.mark(down)
        CotypingSyntheticMarker.mark(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Deletes `deletingCharacters` graphemes (one Backspace each) then types
    /// `text`, in one suppressed synthetic burst. Used to swap a typo for its
    /// correction. Backspace is virtual key 51.
    @discardableResult
    func replace(deletingCharacters count: Int, with text: String) -> Bool {
        let scrubbed = text.replacingOccurrences(of: "\r", with: "")
        guard count > 0 || !scrubbed.isEmpty else { return false }
        var events: [CGEvent] = []
        for _ in 0..<max(0, count) {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: false) else { return false }
            events.append(down)
            events.append(up)
        }
        if !scrubbed.isEmpty {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return false }
            let utf16 = Array(scrubbed.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
            events.append(down)
            events.append(up)
        }
        for event in events { CotypingSyntheticMarker.mark(event) }
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }

    /// Deletes `deletingCharacters` graphemes to the right of the caret (Forward
    /// Delete, virtual key 117) and then types `text`. Used for mid-word accepts
    /// where the model's first characters are already present after the caret.
    @discardableResult
    func replaceForward(deletingCharacters count: Int, with text: String) -> Bool {
        let scrubbed = text.replacingOccurrences(of: "\r", with: "")
        guard count > 0 || !scrubbed.isEmpty else { return false }
        var events: [CGEvent] = []
        for _ in 0..<max(0, count) {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 117, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 117, keyDown: false) else { return false }
            events.append(down)
            events.append(up)
        }
        if !scrubbed.isEmpty {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return false }
            let utf16 = Array(scrubbed.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
            events.append(down)
            events.append(up)
        }
        for event in events { CotypingSyntheticMarker.mark(event) }
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }

    /// Inserts `text` by placing it on the pasteboard and synthesizing a synthetic
    /// Cmd-V, then restoring the user's clipboard shortly after. A trimmed port of
    /// Cotabby's `insertViaPaste`. Used for large / multi-line accepts that some
    /// hosts mishandle as synthetic keystrokes. Returns false on any setup failure
    /// (after restoring the clipboard) so the caller can fall back to keystrokes.
    @discardableResult
    func insertViaPaste(_ text: String) -> Bool {
        let scrubbed = text.replacingOccurrences(of: "\r", with: "")
        guard !scrubbed.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshotPasteboard(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(scrubbed, forType: .string) else {
            Self.restorePasteboard(saved, to: pasteboard)
            return false
        }
        let expectedChangeCount = pasteboard.changeCount
        guard let vDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) else {
            Self.restorePasteboard(saved, to: pasteboard)
            return false
        }
        // Cmd via flags (no separate modifier key event). Marked synthetic so the
        // consuming input tap ignores it.
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        CotypingSyntheticMarker.mark(vDown)
        CotypingSyntheticMarker.mark(vUp)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)

        let restore = DispatchWorkItem { [weak self] in
            if NSPasteboard.general.changeCount == expectedChangeCount {
                Self.restorePasteboard(saved, to: NSPasteboard.general)
            }
            self?.pendingPasteboardRestore = nil
        }
        pendingPasteboardRestore?.cancel()
        pendingPasteboardRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteboardRestoreDelay, execute: restore)
        return true
    }

    /// How long the completion stays on the pasteboard before the user's clipboard
    /// is restored — long enough for the host to service Cmd-V, short enough that
    /// the user's clipboard is theirs again almost immediately.
    private static let pasteboardRestoreDelay: TimeInterval = 0.3

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
