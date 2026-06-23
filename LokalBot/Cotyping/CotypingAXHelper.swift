import AppKit
import ApplicationServices

/// The Accessibility boundary for cotyping. Resolves the system-wide focused
/// element into a value-type `CotypingField` (preceding/trailing text, caret
/// rect in global Cocoa coords, capability). A trimmed port of Cotabby's
/// `AXHelper` + `FocusSnapshotResolver` + `AXTextGeometryResolver`: caret
/// geometry is the zero-length `kAXBoundsForRange` query (exact) with an
/// element-frame estimate fallback.
///
/// All reads go through a system-wide element with a short messaging timeout so a
/// wedged target app degrades to a missed poll, never a beachball.
enum CotypingAXHelper {
    /// Roles we treat as editable text surfaces.
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    /// Bounded context windows so a giant document never ships megabytes into a
    /// prompt or across the actor boundary.
    private static let maxPrecedingCharacters = 4096
    private static let maxTrailingCharacters = 1024

    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }()

    /// True when the process holds the Accessibility grant (no prompt).
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Resolve the current focus into a cotyping snapshot. Pure read; safe to
    /// call from the focus-tracker timer on the main thread.
    static func resolveFocus(includeSurface: Bool = false, includeURL: Bool = false) -> CotypingFocus {
        guard isTrusted else {
            return CotypingFocus(appName: "", bundleID: nil,
                                 capability: .unsupported("Accessibility permission needed."),
                                 field: nil)
        }
        guard let element = focusedElement() else { return .none }

        let owner = owningApp(of: element)
        let appName = owner?.name ?? ""
        let bundleID = owner?.bundleID
        let pid = owner?.pid ?? 0

        let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute as String)

        // Secure fields: never read or suggest into them.
        if subrole == (kAXSecureTextFieldSubrole as String) {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .blocked("Secure field — never read."), field: nil)
        }

        let isEditable = editableRoles.contains(role) || isAttributeSettable(element, kAXValueAttribute as String)
        guard isEditable, let value = stringAttribute(element, kAXValueAttribute as String) else {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("Not an editable text field."), field: nil)
        }

        guard let selection = selectionRange(element) else {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("No caret in this field."), field: nil)
        }

        if selection.length > 0 {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .blocked("Text selected."), field: nil)
        }

        let nsValue = value as NSString
        let caret = max(0, min(selection.location, nsValue.length))
        let precedingFull = nsValue.substring(to: caret)
        let trailingFull = nsValue.substring(from: caret)
        let preceding = String(precedingFull.suffix(maxPrecedingCharacters))
        let trailing = String(trailingFull.prefix(maxTrailingCharacters))

        let (caretRect, exact) = caretRect(element, caretLocation: caret)
        // App/window context — only read when actually building a suggestion (it
        // costs extra AX round-trips), gated by the cotyping setting upstream.
        let surfaceTitle = includeSurface ? windowTitle(near: element) : nil
        let surfacePlaceholder = includeSurface
            ? stringAttribute(element, kAXPlaceholderValueAttribute as String) : nil
        // Per-site rules: read the tab URL only when domains are configured (it
        // costs an extra bounded ancestor walk), gated by the coordinator.
        let host = includeURL ? webURL(near: element).flatMap(CotypingBrowserDomain.host(fromURLString:)) : nil

        let field = CotypingField(
            appName: appName, bundleID: bundleID, processID: pid, role: role,
            precedingText: preceding, trailingText: trailing,
            selectionLength: selection.length, caretRect: caretRect,
            isSecure: false, caretIsExact: exact,
            windowTitle: surfaceTitle, fieldPlaceholder: surfacePlaceholder)
        return CotypingFocus(appName: appName, bundleID: bundleID, capability: .supported, field: field, host: host)
    }

    /// Best-effort title of the window containing `element`: `kAXWindowAttribute`
    /// → `kAXTitleAttribute`. One bounded round-trip; nil on miss. Carries the
    /// email subject, document name, channel, or page title.
    private static func windowTitle(near element: AXUIElement) -> String? {
        guard let raw = copyAttribute(element, kAXWindowAttribute as String),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return stringAttribute(raw as! AXUIElement, kAXTitleAttribute as String)
    }

    /// Best-effort, fail-safe read of the focused tab's URL near `element`, for
    /// per-site rules. Browsers expose `kAXURLAttribute` on the web area or window
    /// rather than the focused field, so walk up a bounded number of ancestors.
    /// Nil on any miss (non-browser, attribute absent, climb exhausted) — a failed
    /// read degrades to "no per-site rule applies". Never mutates AX state.
    private static func webURL(near element: AXUIElement, maxClimb: Int = 6) -> String? {
        var current = element
        for _ in 0...maxClimb {
            if let url = urlString(on: current) { return url }
            guard let parent = parentElement(of: current) else { break }
            current = parent
        }
        return nil
    }

    /// Reads `kAXURLAttribute` as a string, tolerating a `URL`/`NSURL` (the usual
    /// case) or an already-string value.
    private static func urlString(on element: AXUIElement) -> String? {
        guard let value = copyAttribute(element, kAXURLAttribute as String) else { return nil }
        if let url = value as? URL { return url.absoluteString }
        if let url = value as? NSURL { return url.absoluteString }
        return value as? String
    }

    private static func parentElement(of element: AXUIElement) -> AXUIElement? {
        guard let raw = copyAttribute(element, kAXParentAttribute as String),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    // MARK: - Element + owner

    static func focusedElement() -> AXUIElement? {
        guard let raw = copyAttribute(systemWide, kAXFocusedUIElementAttribute as String),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        // `systemWide`'s timeout is already process-global (per AXUIElement.h, a
        // system-wide timeout applies to every element using the default), but pin
        // it on the focused element too so a wedged target app can never block the
        // main-thread reads in `resolveFocus` past 50 ms regardless of global state.
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }

    private static func owningApp(of element: AXUIElement) -> (name: String, bundleID: String?, pid: pid_t)? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return (name: "", bundleID: nil, pid: pid)
        }
        return (name: app.localizedName ?? "", bundleID: app.bundleIdentifier, pid: pid)
    }

    // MARK: - Attribute readers

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

    private static func isAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    /// The caret/selection as an NSRange (UTF-16). `length == 0` is a caret.
    private static func selectionRange(_ element: AXUIElement) -> NSRange? {
        guard let raw = copyAttribute(element, kAXSelectedTextRangeAttribute as String),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    // MARK: - Caret geometry

    /// Returns the caret rect in global Cocoa coordinates and whether it is
    /// exact (from a range query) vs an element-frame estimate.
    private static func caretRect(_ element: AXUIElement, caretLocation: Int) -> (rect: CGRect, exact: Bool) {
        if let rect = boundsForRange(element, location: caretLocation, length: 0),
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
        // Fallback: estimate a thin caret at the element's leading edge.
        if let frame = elementFrame(element) {
            let estimate = CGRect(x: frame.minX + 4, y: frame.minY,
                                  width: 1, height: min(max(frame.height, 8), 22))
            return (cocoaRect(fromAX: estimate), false)
        }
        return (.zero, false)
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

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
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

    /// Accessibility rects are top-left origin against the primary display.
    /// Flip to bottom-left-origin global Cocoa coordinates the overlay panel uses.
    static func cocoaRect(fromAX axRect: CGRect) -> CGRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: axRect.origin.x,
                      y: primaryHeight - axRect.origin.y - axRect.height,
                      width: axRect.width, height: axRect.height)
    }
}
