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
}
