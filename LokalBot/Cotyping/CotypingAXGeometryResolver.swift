import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Resolves caret geometry and AX-to-Cocoa coordinate conversion independently
/// from focus, privacy, and text-capture policy.
enum CotypingAXGeometryResolver {
    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    // MARK: - Caret geometry

    /// Returns the caret rect in global Cocoa coordinates and whether it is
    /// exact (from a range query) vs an element-frame estimate.
    static func caretRect(
        _ element: AXUIElement,
        caretLocation: Int,
        fieldText: String,
        isRightToLeft: Bool,
        allowBoundsForRange: Bool = true
    ) -> (rect: CGRect, exact: Bool) {
        if allowBoundsForRange,
           let rect = boundsForRange(element, location: caretLocation, length: 0),
           rect.width.isFinite, rect.height.isFinite, rect.height > 0 {
            return (cocoaRect(fromAX: rect), true)
        }
        // Web engines (Chromium / WebKit / Electron) ignore NSRange-based
        // BoundsForRange and expose caret geometry only via opaque AX text
        // markers. This is what fixes ghost placement in Chrome/Slack/VS Code-web.
        if let rect = textMarkerCaretRect(element),
           rect.width.isFinite, rect.height.isFinite, rect.height > 0 {
            return (cocoaRect(fromAX: rect), true)
        }
        // Chromium/Electron return zero-size rects from both queries above for
        // a collapsed caret (measured in Chrome and Discord), but Blink still
        // exposes each text run as an AXStaticText child with a tight frame:
        // with the caret at the end of the text, the last run's trailing edge
        // is the caret. This is what fixes inline ghost placement in Discord.
        if CotypingTextLeafCaret.caretIsAtTextEnd(fieldText: fieldText, caretLocation: caretLocation),
           let frame = elementFrame(element),
           let rect = CotypingTextLeafCaret.caretRect(
               elementFrame: frame,
               leaves: staticTextLeaves(element),
               fieldText: fieldText,
               caretLocation: caretLocation,
               isRightToLeft: isRightToLeft) {
            return (cocoaRect(fromAX: rect), true)
        }
        // Fallback: estimate a thin caret at the element's leading edge.
        if let frame = elementFrame(element) {
            let estimate = CGRect(x: frame.minX + 4, y: frame.minY,
                                  width: 1, height: min(max(frame.height, 8), 22))
            return (cocoaRect(fromAX: estimate), false)
        }
        return (.zero, false)
    }

    /// AXStaticText descendants of an editable in tree order — Blink's
    /// text-run boxes. Bounded walk: web composers keep this subtree tiny,
    /// and it only runs after both precise caret queries have failed.
    private static func staticTextLeaves(
        _ element: AXUIElement,
        maxNodes: Int = 200,
        maxDepth: Int = 8
    ) -> [CotypingTextLeafCaret.Leaf] {
        var leaves: [CotypingTextLeafCaret.Leaf] = []
        var budget = maxNodes
        func walk(_ node: AXUIElement, depth: Int) {
            guard depth < maxDepth, budget > 0,
                  let raw = copyAttribute(node, kAXChildrenAttribute as String),
                  let children = raw as? [AXUIElement] else { return }
            for child in children {
                guard budget > 0 else { return }
                budget -= 1
                if stringAttribute(child, kAXRoleAttribute as String) == kAXStaticTextRole as String {
                    guard let frame = elementFrame(child) else { continue }
                    let text = stringAttribute(child, kAXValueAttribute as String) ?? ""
                    leaves.append(CotypingTextLeafCaret.Leaf(frame: frame, text: text))
                } else {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(element, depth: 0)
        return leaves
    }

    private static func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var cfRange = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var raw: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &raw)
        guard err == .success, let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Caret rect for web engines that vend geometry via opaque AX text markers
    /// (`AXSelectedTextMarkerRange` → `AXBoundsForTextMarkerRange`) rather than
    /// NSRange-based `AXBoundsForRange`. Ported from Cotabby's AXHelper.
    private static func textMarkerCaretRect(_ element: AXUIElement) -> CGRect? {
        var markerRangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, &markerRangeValue) == .success,
              let markerRange = markerRangeValue else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &boundsValue) == .success,
              let bounds = boundsValue, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    static func elementFrame(_ element: AXUIElement) -> CGRect? {
        guard let posRaw = copyAttribute(element, kAXPositionAttribute as String),
              CFGetTypeID(posRaw) == AXValueGetTypeID(),
              let sizeRaw = copyAttribute(element, kAXSizeAttribute as String),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRaw as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Accessibility rects are top-left-origin display coordinates. Flip through
    /// the actual display/screen pair containing the caret so external displays do
    /// not inherit the primary display's height.
    static func cocoaRect(fromAX axRect: CGRect) -> CGRect {
        let midpoint = CGPoint(x: axRect.midX, y: axRect.midY)
        if let displayID = displayID(containingAXPoint: midpoint),
           let screen = screen(forDisplayID: displayID) {
            return cocoaRect(fromAX: axRect,
                             displayBounds: CGDisplayBounds(displayID),
                             screenFrame: screen.frame)
        }
        let primaryBounds = CGDisplayBounds(CGMainDisplayID())
        let primaryFrame = NSScreen.main?.frame ?? CGRect(origin: .zero, size: primaryBounds.size)
        return cocoaRect(fromAX: axRect, displayBounds: primaryBounds, screenFrame: primaryFrame)
    }

    static func cocoaRect(fromAX axRect: CGRect,
                          displayBounds: CGRect,
                          screenFrame: CGRect) -> CGRect {
        let localX = axRect.origin.x - displayBounds.origin.x
        let localYFromTop = axRect.origin.y - displayBounds.origin.y
        return CGRect(x: screenFrame.origin.x + localX,
                      y: screenFrame.maxY - localYFromTop - axRect.height,
                      width: axRect.width, height: axRect.height)
    }

    private static func displayID(containingAXPoint point: CGPoint) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayBounds($0).contains(point) }
    }

    private static func screen(forDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }
    }
}
