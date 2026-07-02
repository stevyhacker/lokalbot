import CoreGraphics

/// Pure placement math for the ghost overlay, split out from `show()` so the
/// frame geometry is deterministic and unit-testable. All rects are in global
/// Cocoa (bottom-left origin) coordinates.
nonisolated enum CotypingOverlayGeometry {
    /// Gap between the caret and the suggestion / screen edges.
    static let gap: CGFloat = 2
    static let reanchorDriftTolerance: CGFloat = 6
    static let backwardDriftHoldWindowMilliseconds = 300

    /// Inline ghost frame: the suggestion sits just right of the caret with its
    /// line box centered on the caret's vertical center. The panel height tracks
    /// the ghost text's own line height — never the host caret height, which
    /// varies between AppKit (`AXBoundsForRange`) and WebKit/Chromium
    /// (`AXBoundsForTextMarkerRange`) providers — so vertical placement is
    /// consistent across apps. Clamps to the visible frame's right/bottom edges.
    static func inlineFrame(
        caret: CGRect, textSize: CGSize, lineHeight: CGFloat, visible: CGRect?
    ) -> CGRect {
        let height = max(textSize.height, lineHeight, 1)
        let width = max(textSize.width, 8)
        var x = caret.maxX + gap
        if let visible, x + width > visible.maxX {
            x = max(visible.minX + gap, visible.maxX - width - gap)
        }
        var y = caret.midY - height / 2
        if let visible, y < visible.minY { y = visible.minY + gap }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Frame for a same-line inline ghost after accepting its leading text. The
    /// caller falls back to a fresh caret anchor when the slide would overflow.
    static func advancedInlineFrame(
        from frame: CGRect,
        insertedTextSize: CGSize,
        remainingTextSize: CGSize,
        lineHeight: CGFloat,
        visible: CGRect?
    ) -> CGRect? {
        let shift = insertedTextSize.width
        guard shift.isFinite, shift > 0,
              frame.origin.x.isFinite, frame.origin.y.isFinite else {
            return nil
        }
        let height = max(remainingTextSize.height, lineHeight, 1)
        let width = max(remainingTextSize.width, 8)
        var advanced = CGRect(
            x: frame.minX + shift,
            y: frame.midY - height / 2,
            width: width,
            height: height)
        if let visible {
            guard advanced.minX >= visible.minX + gap,
                  advanced.maxX <= visible.maxX - gap else {
                return nil
            }
            if advanced.minY < visible.minY {
                advanced.origin.y = visible.minY + gap
            }
        }
        return advanced
    }

    /// CoTabby-style post-accept stability rule for inline ghosts. Hold small
    /// same-text drift, and briefly hold larger backward jumps because AX often
    /// publishes inserted text before its caret frames catch up.
    static func shouldHoldInlineReanchor(
        currentFrame: CGRect,
        targetFrame: CGRect,
        millisecondsSinceLastAcceptance: Int?,
        isRightToLeft: Bool = false
    ) -> Bool {
        let deltaY = targetFrame.origin.y - currentFrame.origin.y
        guard abs(deltaY) <= reanchorDriftTolerance else { return false }

        let deltaX = targetFrame.origin.x - currentFrame.origin.x
        if abs(deltaX) <= reanchorDriftTolerance {
            return true
        }
        let isBackward = isRightToLeft
            ? deltaX > reanchorDriftTolerance
            : deltaX < -reanchorDriftTolerance
        let insideHoldWindow = millisecondsSinceLastAcceptance
            .map { $0 <= backwardDriftHoldWindowMilliseconds } ?? false
        return isBackward && insideHoldWindow
    }

    /// Mirror (popup) frame: a chrome pill one line below the caret, flipped
    /// above when there is no room below. Used for mid-line carets where inline
    /// text would paint over the host's trailing characters.
    static func mirrorFrame(
        caret: CGRect, content: CGSize, visible: CGRect?
    ) -> CGRect {
        let width = max(content.width, 8)
        let height = max(content.height, 18)
        var x = min(caret.minX, (visible?.maxX ?? caret.minX) - width)
        if let visible { x = max(visible.minX + gap, x) }
        var y = caret.minY - height - gap
        if let visible, y < visible.minY { y = caret.maxY + gap }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
