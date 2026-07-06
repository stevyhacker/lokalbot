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
    /// prompt or across the actor boundary. `maxPrecedingCharacters` is the
    /// canonical preceding-window limit — session reconciliation
    /// (`CotypingSessionReconciler`) and marker-selection synthesis reference
    /// it so capped-window comparisons can never drift from the AX read path.
    static let maxPrecedingCharacters = 4096
    private static let maxTrailingCharacters = 1024

    private static let selectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange" as CFString
    private static let startTextMarkerAttribute = "AXStartTextMarker" as CFString
    private static let endTextMarkerAttribute = "AXEndTextMarker" as CFString
    private static let startMarkerForRangeAttribute = "AXStartTextMarkerForTextMarkerRange" as CFString
    private static let endMarkerForRangeAttribute = "AXEndTextMarkerForTextMarkerRange" as CFString
    private static let markerRangeForMarkersAttribute = "AXTextMarkerRangeForUnorderedTextMarkers" as CFString
    private static let stringForMarkerRangeAttribute = "AXStringForTextMarkerRange" as CFString

    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }()

    /// True when the process holds the Accessibility grant (no prompt).
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Per-element cache of resolved field styles so the focus poll (every ~200 ms)
    /// doesn't re-read `AXAttributedStringForRange` for a field it already styled.
    /// Keyed by the element's stable `AXIdentifier`; cleared wholesale at 64 entries.
    @MainActor private static var fieldStyleCache: [String: CotypingFieldStyle] = [:]
    @MainActor private static var surfaceCaptureCache = CotypingSurfaceCaptureCache()
    @MainActor private static var primedWebAccessibilityPIDs: Set<pid_t> = []
    @MainActor private static var unsupportedWebAccessibilityPIDs: Set<pid_t> = []
    @MainActor private static var lastFrontmostPrimePID: pid_t?
    @MainActor private static var chromiumHitTestCache: (element: AXUIElement, pid: pid_t)?

    /// Resolve the current focus into a cotyping snapshot. Pure read; safe to
    /// call from the focus-tracker timer on the main thread.
    @MainActor
    static func resolveFocus(includeSurface: Bool = false, includeURL: Bool = false, includeStyle: Bool = false) -> CotypingFocus {
        guard isTrusted else {
            return CotypingFocus(appName: "", bundleID: nil,
                                 capability: .unsupported("Accessibility permission needed."),
                                 field: nil)
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            primeWebAccessibilityIfNeeded(application: frontmost)
        }
        guard let element = focusedElement() else { return .none }

        let owner = owningApp(of: element)
        let appName = owner?.name ?? ""
        let bundleID = owner?.bundleID
        let pid = owner?.pid ?? 0

        let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute as String)
        let focusIdentityKey = focusIdentityKey(
            for: element, processID: pid, bundleID: bundleID, role: role, subrole: subrole)

        // Secure fields: never read or suggest into them. Some hosts only
        // expose sensitivity through role description/title/description, so
        // check all cheap metadata before touching AXValue.
        let roleDescription = stringAttribute(element, kAXRoleDescriptionAttribute as String)
        let title = stringAttribute(element, kAXTitleAttribute as String)
        let descriptionLabel = stringAttribute(element, kAXDescriptionAttribute as String)
        if CotypingSecureFieldDetector.isSecure(
            role: role,
            subrole: subrole,
            roleDescription: roleDescription,
            title: title,
            descriptionLabel: descriptionLabel) {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .blocked("Secure field — never read."), field: nil)
        }

        let isEditable = editableRoles.contains(role) || isAttributeSettable(element, kAXValueAttribute as String)
        guard isEditable else {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("Not an editable text field."), field: nil)
        }

        let nativeSelection = selectionRange(element)
        let markerSelection = nativeSelection == nil ? synthesizeMarkerSelection(on: element) : nil
        let usesMarkerSelection = markerSelection != nil

        guard let value = markerSelection?.text ?? stringAttribute(element, kAXValueAttribute as String) else {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("Not an editable text field."), field: nil)
        }

        guard let selection = markerSelection?.selection ?? nativeSelection else {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("No caret in this field."), field: nil)
        }

        if selection.length > 0 {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .blocked("Text selected."), field: nil,
                                 focusIdentityKey: focusIdentityKey)
        }

        let nsValue = value as NSString
        let caret = max(0, min(selection.location, nsValue.length))
        let precedingFull = nsValue.substring(to: caret)
        let trailingFull = nsValue.substring(from: caret)
        let preceding = String(precedingFull.suffix(maxPrecedingCharacters))
        let trailing = String(trailingFull.prefix(maxTrailingCharacters))

        let (caretRect, exact) = caretRect(
            element,
            caretLocation: caret,
            fieldText: value,
            isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(preceding),
            allowBoundsForRange: !usesMarkerSelection)
        let inputFrameRect = elementFrame(element).map { cocoaRect(fromAX: $0) }
        // App/window context — only read when actually building a suggestion (it
        // costs extra AX round-trips), gated by the cotyping setting upstream.
        let surfaceCapture = resolveSurfaceCapture(
            element: element,
            processID: pid,
            bundleID: bundleID,
            role: role,
            subrole: subrole,
            focusIdentityKey: focusIdentityKey,
            inputFrameRect: inputFrameRect,
            includeSurface: includeSurface,
            includeURL: includeURL)
        let surfaceTitle = includeSurface ? surfaceCapture.windowTitle : nil
        let surfacePlaceholder = includeSurface ? surfaceCapture.fieldPlaceholder : nil
        // Per-site rules: read the tab URL only when domains are configured (it
        // costs an extra bounded ancestor walk), gated by the coordinator.
        let host = includeURL ? surfaceCapture.urlString.flatMap(CotypingBrowserDomain.host(fromURLString:)) : nil
        // Host field font/color — read (cached per element) only when matching is
        // enabled, so the overlay can mimic the field instead of a fixed style.
        let resolvedStyle = includeStyle && !usesMarkerSelection
            ? resolveFieldStyle(for: element, caretLocation: caret, textLength: nsValue.length)
            : nil
        let isIntegratedTerminal = CotypingSurfaceClassifier.isIntegratedTerminal(
            domClassList: stringArrayAttribute(element, "AXDOMClassList"))

        let field = CotypingField(
            appName: appName, bundleID: bundleID, processID: pid, role: role,
            focusIdentityKey: focusIdentityKey,
            precedingText: preceding, trailingText: trailing,
            selectionLength: selection.length, caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            isSecure: false, isIntegratedTerminal: isIntegratedTerminal, caretIsExact: exact,
            windowTitle: surfaceTitle, fieldPlaceholder: surfacePlaceholder, fieldStyle: resolvedStyle)
        return CotypingFocus(appName: appName, bundleID: bundleID, capability: .supported,
                             field: field, focusIdentityKey: focusIdentityKey, host: host)
    }

    private static func focusIdentityKey(
        for element: AXUIElement,
        processID: pid_t,
        bundleID: String?,
        role: String,
        subrole: String?
    ) -> String {
        let axIdentifier = stringAttribute(element, kAXIdentifierAttribute as String)
            .flatMap { $0.isEmpty ? nil : $0 }
        let elementPart = axIdentifier ?? "cf:\(CFHash(element))"
        return [
            String(processID),
            bundleID ?? "",
            role,
            subrole ?? "",
            elementPart
        ].joined(separator: "\u{1f}")
    }

    /// Wakes Chromium/Electron web accessibility trees lazily, matching
    /// CoTabby's focus pipeline. Safe to call on every poll: successful and
    /// unsupported PIDs are cached, while named Electron editors get one
    /// re-assertion per activation edge.
    @MainActor
    private static func primeWebAccessibilityIfNeeded(application: NSRunningApplication) {
        let pid = application.processIdentifier
        let bundleID = application.bundleIdentifier
        let isActivationEdge = pid != lastFrontmostPrimePID
        lastFrontmostPrimePID = pid

        guard pid > 0,
              needsWebAccessibilityPriming(bundleID: bundleID),
              !unsupportedWebAccessibilityPIDs.contains(pid) else {
            return
        }

        let reassertForElectronEditor = isActivationEdge && isElectronEditor(bundleID: bundleID)
        guard !primedWebAccessibilityPIDs.contains(pid) || reassertForElectronEditor else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        let value: CFBoolean = kCFBooleanTrue
        switch AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, value) {
        case .success:
            primedWebAccessibilityPIDs.insert(pid)
        case .attributeUnsupported:
            unsupportedWebAccessibilityPIDs.insert(pid)
        default:
            break
        }
    }

    nonisolated static func needsWebAccessibilityPriming(bundleID: String?) -> Bool {
        isChromiumBrowser(bundleID: bundleID) || isElectronEditor(bundleID: bundleID)
    }

    private nonisolated static func isChromiumBrowser(bundleID: String?) -> Bool {
        hasMatchingPrefix(bundleID, in: [
            "com.google.chrome",
            "company.thebrowser.browser",
            "com.brave.browser",
            "com.microsoft.edgemac",
        ])
    }

    nonisolated static func isElectronEditor(bundleID: String?) -> Bool {
        guard let lowered = bundleID?.lowercased() else { return false }
        return [
            "com.clickup.desktop-app",
            "com.microsoft.vscode",
            "com.microsoft.vscodeinsiders",
            "com.vscodium",
        ].contains(lowered)
    }

    private nonisolated static func hasMatchingPrefix(_ bundleID: String?, in prefixes: [String]) -> Bool {
        guard let lowered = bundleID?.lowercased() else { return false }
        return prefixes.contains { lowered.hasPrefix($0) }
    }

    /// Chromium/WebKit contenteditable fields can expose caret text through the
    /// opaque text-marker API instead of `AXSelectedTextRange`. The marker reads
    /// are best-effort and never cached; nil means the existing native-range
    /// unsupported path remains in force.
    private static func synthesizeMarkerSelection(on element: AXUIElement) -> CotypingMarkerSelection? {
        let parameterized = Set(parameterizedAttributeNames(on: element))
        guard parameterized.contains(startMarkerForRangeAttribute as String),
              parameterized.contains(endMarkerForRangeAttribute as String),
              parameterized.contains(markerRangeForMarkersAttribute as String),
              parameterized.contains(stringForMarkerRangeAttribute as String)
        else {
            return nil
        }

        guard let selectionRange = copyOpaqueAttribute(selectedTextMarkerRangeAttribute, on: element),
              let documentStart = copyOpaqueAttribute(startTextMarkerAttribute, on: element),
              let documentEnd = copyOpaqueAttribute(endTextMarkerAttribute, on: element),
              let selectionStart = copyOpaqueParameterized(
                startMarkerForRangeAttribute, parameter: selectionRange, on: element),
              let selectionEnd = copyOpaqueParameterized(
                endMarkerForRangeAttribute, parameter: selectionRange, on: element)
        else {
            return nil
        }

        guard let preRange = markerRange(from: documentStart, to: selectionStart, on: element),
              let beforeText = stringForMarkerRange(preRange, on: element) else {
            return nil
        }

        let selectedText = stringForMarkerRange(selectionRange, on: element) ?? ""
        let afterText: String
        if let postRange = markerRange(from: selectionEnd, to: documentEnd, on: element),
           let trailing = stringForMarkerRange(postRange, on: element) {
            afterText = trailing
        } else {
            afterText = ""
        }

        return CotypingMarkerSelectionSynthesizer.make(
            beforeCaret: beforeText,
            selected: selectedText,
            afterCaret: afterText)
    }

    private static func markerRange(
        from start: CFTypeRef,
        to end: CFTypeRef,
        on element: AXUIElement
    ) -> CFTypeRef? {
        let markers = [start, end] as CFArray
        return copyOpaqueParameterized(markerRangeForMarkersAttribute, parameter: markers, on: element)
    }

    private static func stringForMarkerRange(_ range: CFTypeRef, on element: AXUIElement) -> String? {
        copyOpaqueParameterized(stringForMarkerRangeAttribute, parameter: range, on: element) as? String
    }

    /// Reads the focused field's own font + text color (cached per element) so
    /// the ghost overlay can match it. Best-effort: nil on any miss → overlay
    /// defaults. The parameterized attributed-string read is a synchronous
    /// cross-process call, so it is cached and gated behind `includeStyle`.
    @MainActor
    private static func resolveFieldStyle(for element: AXUIElement, caretLocation: Int, textLength: Int) -> CotypingFieldStyle? {
        guard textLength > 0 else { return nil }
        let identifier = stringAttribute(element, kAXIdentifierAttribute as String)
        if let identifier, !identifier.isEmpty, let cached = fieldStyleCache[identifier] {
            return cached
        }
        // Prefer the character just before the caret (what the user is extending),
        // then the first character; clamp so an off-by-one caret never reads OOB.
        let clampedCaret = min(max(caretLocation - 1, 0), textLength - 1)
        let candidateIndices = clampedCaret == 0 ? [0] : [clampedCaret, 0]
        var resolved: CotypingFieldStyle?
        for index in candidateIndices {
            guard let attributed = attributedString(forRange: NSRange(location: index, length: 1), on: element),
                  attributed.length > 0,
                  let style = extractFieldStyle(from: attributed.attributes(at: 0, effectiveRange: nil)) else { continue }
            resolved = style
            break
        }
        if let identifier, !identifier.isEmpty, let resolved {
            fieldStyleCache[identifier] = resolved
            if fieldStyleCache.count > 64 { fieldStyleCache.removeAll() }
        }
        return resolved
    }

    private static func attributedString(forRange range: NSRange, on element: AXUIElement) -> NSAttributedString? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXAttributedStringForRange" as CFString, axRange, &value) == .success else { return nil }
        return value as? NSAttributedString
    }

    /// Extracts a `CotypingFieldStyle` from one character's attributes, handling
    /// both the AppKit `.font`/`.foregroundColor` shapes and the AX font-dict /
    /// CGColor shapes AX returns from web content.
    private static func extractFieldStyle(from attributes: [NSAttributedString.Key: Any]) -> CotypingFieldStyle? {
        var fontName: String?
        var fontPointSize: CGFloat?
        if let font = attributes[.font] as? NSFont {
            fontName = font.fontName
            fontPointSize = font.pointSize
        } else if let fontInfo = attributes[NSAttributedString.Key("AXFont")] as? [String: Any] {
            fontName = fontInfo["AXFontName"] as? String
            if let size = fontInfo["AXFontSize"] as? NSNumber { fontPointSize = CGFloat(size.doubleValue) }
        }
        let foregroundHex = colorAttribute(in: attributes, forKey: .foregroundColor)
        // Web/AX content sometimes reports the fill under an `AXBackgroundColor`
        // run attribute rather than the AppKit `.backgroundColor` key.
        let backgroundHex = colorAttribute(in: attributes, forKey: .backgroundColor)
            ?? colorAttribute(in: attributes, forKey: NSAttributedString.Key("AXBackgroundColor"))
        let style = CotypingFieldStyle(
            fontName: fontName, fontPointSize: fontPointSize,
            colorHex: foregroundHex, backgroundColorHex: backgroundHex)
        return style.isEmpty ? nil : style
    }

    /// Extracts a 6-digit hex color from a run attribute, handling both the
    /// AppKit `NSColor` shape and the `CGColor` shape AX returns from web content
    /// (a conditional `as?` to `CGColor` does not compile against `Any`, so the CF
    /// type id is verified before the force-cast).
    private static func colorAttribute(in attributes: [NSAttributedString.Key: Any],
                                       forKey key: NSAttributedString.Key) -> String? {
        guard let value = attributes[key] else { return nil }
        if let nsColor = value as? NSColor {
            return CotypingTextColorCodec.hexString(from: nsColor)
        }
        if CFGetTypeID(value as CFTypeRef) == CGColor.typeID,
           let nsColor = NSColor(cgColor: value as! CGColor) {
            return CotypingTextColorCodec.hexString(from: nsColor)
        }
        return nil
    }

    /// Best-effort title of the window containing `element`: `kAXWindowAttribute`
    /// → `kAXTitleAttribute`. One bounded round-trip; nil on miss. Carries the
    /// email subject, document name, channel, or page title.
    private static func windowTitle(near element: AXUIElement) -> String? {
        guard let raw = copyAttribute(element, kAXWindowAttribute as String),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return stringAttribute(raw as! AXUIElement, kAXTitleAttribute as String)
    }

    @MainActor
    private static func resolveSurfaceCapture(
        element: AXUIElement,
        processID: pid_t,
        bundleID: String?,
        role: String,
        subrole: String?,
        focusIdentityKey: String?,
        inputFrameRect: CGRect?,
        includeSurface: Bool,
        includeURL: Bool
    ) -> CotypingSurfaceCapture {
        guard includeSurface || includeURL else { return .empty }
        let key = CotypingSurfaceCaptureCache.key(
            processID: processID,
            bundleID: bundleID,
            role: role,
            subrole: subrole,
            focusIdentityKey: focusIdentityKey,
            inputFrameRect: inputFrameRect,
            includeSurface: includeSurface,
            includeURL: includeURL)
        return surfaceCaptureCache.capture(forKey: key) {
            CotypingSurfaceCapture(
                windowTitle: includeSurface ? windowTitle(near: element) : nil,
                fieldPlaceholder: includeSurface ? stringAttribute(element, kAXPlaceholderValueAttribute as String) : nil,
                urlString: includeURL ? webURL(near: element) : nil)
        }
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

    @MainActor
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
            chromiumHitTestCache = nil
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

    @MainActor
    private static func chromiumHitTestFallback(for application: NSRunningApplication) -> AXUIElement? {
        let pid = application.processIdentifier
        guard pid > 0,
              needsWebAccessibilityPriming(bundleID: application.bundleIdentifier) else {
            chromiumHitTestCache = nil
            return nil
        }

        if let cache = chromiumHitTestCache,
           cache.pid == pid,
           isFocused(cache.element) {
            return cache.element
        }
        chromiumHitTestCache = nil

        guard let hit = element(atCocoaPoint: NSEvent.mouseLocation) else {
            return nil
        }
        let editable = nearestEditable(from: hit)
        chromiumHitTestCache = (editable, pid)
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

    /// Climb from a Chromium hit-test leaf to the nearest likely editable
    /// container. Final support still depends on the normal `resolveFocus`
    /// value/selection/caret checks, so a wrong leaf degrades to unsupported.
    private static func nearestEditable(from element: AXUIElement, maxClimb: Int = 5) -> AXUIElement {
        var current = element
        for _ in 0...maxClimb {
            let role = stringAttribute(current, kAXRoleAttribute as String) ?? ""
            let attributes = Set(attributeNames(on: current))
            let explicitEditable = attributes.contains("AXEditable")
                ? boolAttribute(current, "AXEditable")
                : nil
            if editableRoles.contains(role)
                || explicitEditable == true
                || attributes.contains(selectedTextMarkerRangeAttribute as String) {
                return current
            }
            guard let parent = parentElement(of: current) else { break }
            current = parent
        }
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

    static func owningApplication(of element: AXUIElement) -> NSRunningApplication? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    /// Locates the host app's Paste command by its Cmd-V key equivalent rather
    /// than localized title. The IME-safe paste path presses this menu item when
    /// available so no keyboard event can be reinterpreted by the input method.
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

    // MARK: - Attribute readers

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func copyOpaqueAttribute(_ attribute: CFString, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    private static func copyOpaqueParameterized(
        _ attribute: CFString,
        parameter: CFTypeRef,
        on element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &value) == .success else {
            return nil
        }
        return value
    }

    private static func attributeNames(on element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let names else {
            return []
        }
        return names as? [String] ?? []
    }

    private static func parameterizedAttributeNames(on element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success,
              let names else {
            return []
        }
        return names as? [String] ?? []
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    private static func stringArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [String] {
        copyAttribute(element, attribute) as? [String] ?? []
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copyAttribute(element, attribute) as? Bool
    }

    private static func intAttribute(_ element: AXUIElement, _ attribute: String) -> Int? {
        if let value = copyAttribute(element, attribute) as? Int {
            return value
        }
        return (copyAttribute(element, attribute) as? NSNumber)?.intValue
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        guard let values = copyAttribute(element, kAXChildrenAttribute as String) as? [AnyObject] else {
            return []
        }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    private static func isCommandVMenuItem(_ item: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(item, 0.05)
        guard let cmdChar = stringAttribute(item, kAXMenuItemCmdCharAttribute as String),
              cmdChar.uppercased() == "V",
              let modifiers = intAttribute(item, kAXMenuItemCmdModifiersAttribute as String) else {
            return false
        }
        return modifiers == 0
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
    private static func caretRect(
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
