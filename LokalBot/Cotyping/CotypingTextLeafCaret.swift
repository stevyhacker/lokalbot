import CoreGraphics
import Foundation

/// Derives an exact caret rect from an editable's text-run descendants when
/// both range- and marker-based caret geometry fail.
///
/// Chromium and Electron (measured in Chrome and Discord) return zero-size
/// rects for a collapsed caret from `AXBoundsForRange` *and* from
/// `AXBoundsForTextMarkerRange` on the selection, and they do not implement
/// the marker-extraction attributes that would let us widen the range. But
/// Blink still exposes every laid-out text run as an `AXStaticText` child
/// with a tight pixel frame — so when the caret sits at the end of the text,
/// the last run's trailing edge *is* the caret. Pure geometry over plain
/// values so it is unit-testable without AX.
nonisolated enum CotypingTextLeafCaret {
    struct Leaf {
        /// Top-left-origin AX display coordinates, like all raw AX frames.
        let frame: CGRect
        let text: String
    }

    /// Sanity band for a single text-run box height (points).
    private static let lineHeightBand: ClosedRange<CGFloat> = 4...64
    /// Slack for leaf-inside-element containment (borders, subpixel rounding).
    private static let containmentTolerance: CGFloat = 4

    /// Whether the caret sits at the end of the field's text, tolerating the
    /// trailing newline contenteditable editors keep in an "empty" tail
    /// (Discord's empty composer value is "\n"). Cheap pre-check so callers
    /// can skip the AX subtree walk entirely for mid-text carets.
    static func caretIsAtTextEnd(fieldText: String, caretLocation: Int) -> Bool {
        caretLocation >= trimmedUTF16Length(of: fieldText)
    }

    /// The caret rect in AX coordinates, or nil whenever the derivation would
    /// be a guess: the caret must be at the end of the text, and the last
    /// text run must lie inside the element and match the tail of the text
    /// the field reports (a trailing emoji/mention run the field counts but
    /// the runs don't cover means the edge would be wrong — refuse instead).
    static func caretRect(
        elementFrame: CGRect,
        leaves: [Leaf],
        fieldText: String,
        caretLocation: Int,
        isRightToLeft: Bool
    ) -> CGRect? {
        guard caretIsAtTextEnd(fieldText: fieldText, caretLocation: caretLocation) else {
            return nil
        }
        guard let leaf = leaves.last(where: { !trimmedText($0.text).isEmpty }) else {
            return nil
        }
        let leafText = trimmedText(leaf.text)
        guard trimmedText(fieldText).hasSuffix(leafText) else { return nil }
        guard leaf.frame.width > 0,
              lineHeightBand.contains(leaf.frame.height),
              elementFrame
                  .insetBy(dx: -containmentTolerance, dy: -containmentTolerance)
                  .contains(leaf.frame) else {
            return nil
        }
        let x = isRightToLeft ? leaf.frame.minX : leaf.frame.maxX
        return CGRect(x: x, y: leaf.frame.minY, width: 1, height: leaf.frame.height)
    }

    private static func trimmedText(_ text: String) -> String {
        var result = text
        while let last = result.unicodeScalars.last, CharacterSet.newlines.contains(last) {
            result.unicodeScalars.removeLast()
        }
        return result
    }

    private static func trimmedUTF16Length(of text: String) -> Int {
        (trimmedText(text) as NSString).length
    }
}
