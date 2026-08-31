import AppKit
import ApplicationServices
import Foundation

extension CotypingAXHelper {
    static func focusedElement() -> AXUIElement? {
        if let element = focusedElement(from: systemWide) {
            return element
        }
        // Some Chromium/Electron fields are missed by the system-wide focused
        // element query but still resolve through the app-scoped AX object.
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        if let element = focusedElement(forApplicationPID: frontmost.processIdentifier) {
            cacheState.withLock { cacheState.chromiumHitTest = nil }
            return element
        }
        return chromiumHitTestFallback(for: frontmost)
    }

    private static func focusedElement(forApplicationPID pid: pid_t) -> AXUIElement? {
        guard pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        return focusedElement(from: appElement)
    }

    private static func focusedElement(from root: AXUIElement) -> AXUIElement? {
        guard let raw = copyAttribute(root, kAXFocusedUIElementAttribute as String),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = raw as! AXUIElement
        // Pin the timeout on the focused element too so a wedged target app can
        // never block the main-thread reads in `resolveFocus` past 50 ms.
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }

    private static func chromiumHitTestFallback(for application: NSRunningApplication) -> AXUIElement? {
        let pid = application.processIdentifier
        guard pid > 0,
              needsWebAccessibilityPriming(bundleID: application.bundleIdentifier) else {
            cacheState.withLock { cacheState.chromiumHitTest = nil }
            return nil
        }

        if let cache = cacheState.withLock({ cacheState.chromiumHitTest }),
           cache.pid == pid,
           isUsableHitTestCandidate(cache.element, expectedProcessID: pid) {
            return cache.element
        }
        cacheState.withLock { cacheState.chromiumHitTest = nil }

        guard let hit = element(atCocoaPoint: NSEvent.mouseLocation) else {
            return nil
        }
        guard let editable = nearestEditable(from: hit),
              isUsableHitTestCandidate(editable, expectedProcessID: pid) else {
            return nil
        }
        cacheState.withLock { cacheState.chromiumHitTest = (editable, pid) }
        return editable
    }

    private static func element(atCocoaPoint point: CGPoint) -> AXUIElement? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            return nil
        }
        let axPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide, Float(axPoint.x), Float(axPoint.y), &element) == .success else {
            return nil
        }
        if let element {
            AXUIElementSetMessagingTimeout(element, 0.05)
        }
        return element
    }

    private static func isFocused(_ element: AXUIElement) -> Bool {
        boolAttribute(element, kAXFocusedAttribute as String) ?? false
    }

    private static func isUsableHitTestCandidate(
        _ element: AXUIElement,
        expectedProcessID: pid_t
    ) -> Bool {
        CotypingAXHitTestFocusValidator.canUseCandidate(
            frontmostProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            expectedProcessID: expectedProcessID,
            candidateProcessID: processID(of: element),
            isEditable: isEditableElement(element),
            isFocused: isFocused(element))
    }

    private static func isEditableElement(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
        let attributes = Set(attributeNames(on: element))
        let explicitEditable = attributes.contains("AXEditable")
            ? boolAttribute(element, "AXEditable")
            : nil
        return editableRoles.contains(role)
            || explicitEditable == true
            || attributes.contains(selectedTextMarkerRangeAttribute as String)
    }

    /// Climb from a Chromium hit-test leaf to the nearest likely editable
    /// container. Nil is safer than returning an arbitrary hit-test leaf: event
    /// insertion is global and would target the actually focused element.
    private static func nearestEditable(from element: AXUIElement, maxClimb: Int = 5) -> AXUIElement? {
        var current = element
        for _ in 0...maxClimb {
            if isEditableElement(current) {
                return current
            }
            guard let parent = parentElement(of: current) else { break }
            current = parent
        }
        return nil
    }

    static func processID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    static func owningApp(of element: AXUIElement) -> (name: String, bundleID: String?, pid: pid_t)? {
        guard let pid = processID(of: element) else { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return (name: "", bundleID: nil, pid: pid)
        }
        return (name: app.localizedName ?? "", bundleID: app.bundleIdentifier, pid: pid)
    }

    static func owningApplication(of element: AXUIElement) -> NSRunningApplication? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    /// Locates the host app's Paste command by its Cmd-V key equivalent rather
    /// than localized title. Used only by dictation delivery; cotyping's
    /// consuming event tap never walks host menus or touches the pasteboard.
    static func pasteMenuItem(forApplicationPID pid: pid_t) -> AXUIElement? {
        guard pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        guard let menuBarValue = copyAttribute(appElement, kAXMenuBarAttribute as String),
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let menuBar = menuBarValue as! AXUIElement
        AXUIElementSetMessagingTimeout(menuBar, 0.05)

        for topLevelItem in childElements(of: menuBar) {
            AXUIElementSetMessagingTimeout(topLevelItem, 0.05)
            for menu in childElements(of: topLevelItem) {
                AXUIElementSetMessagingTimeout(menu, 0.05)
                for item in childElements(of: menu) where isCommandVMenuItem(item) {
                    return item
                }
            }
        }
        return nil
    }



    // MARK: - Coordinate conversion compatibility

    static func cocoaRect(
        fromAX axRect: CGRect,
        displayBounds: CGRect,
        screenFrame: CGRect
    ) -> CGRect {
        CotypingAXGeometryResolver.cocoaRect(
            fromAX: axRect,
            displayBounds: displayBounds,
            screenFrame: screenFrame)
    }
}
