import CoreGraphics
import Foundation

/// How an observed keystroke relates to cotyping.
enum CotypingKeyKind: Equatable, Sendable {
    case acceptance    // plain Tab — consumed by the accept tap, reported for awareness
    case dismissal     // Esc / Return / Enter
    case navigation    // arrow keys
    case shortcut      // any Command/Control-modified key
    case textMutation  // printable character, Backspace, or Forward Delete
    case other
}

/// Global keyboard watcher for cotyping. Ported from Cotabby's `InputMonitor`:
///
///  • an always-on **observer** tap (`.listenOnly`, head-insert) that classifies
///    keystrokes so the coordinator can schedule/dismiss — it can never drop
///    events, so it cannot stall other apps; and
///  • an **accept** tap (`.defaultTap`, tail-append) installed only while a
///    suggestion is visible, which returns `nil` to swallow the accept key (Tab)
///    so it lands in the suggestion instead of moving focus.
///
/// Requires the Input Monitoring grant. Cotyping's own synthetic inserts are
/// tagged (`CotypingSyntheticMarker`) and skipped.
@MainActor
final class CotypingInputMonitor {
    /// Fired for every observed keyDown (not the accept key consumption itself).
    var onKey: ((CotypingKeyKind) -> Void)?
    /// Invoked by the accept tap when Tab should be consumed. Returns `true` if
    /// it acted on a suggestion (then Tab is swallowed); `false` → pass through.
    var onAcceptKey: (() -> Bool)?
    /// Consulted at event time: should the accept tap even consider this key?
    /// (The coordinator sets this to "overlay visible".)
    var acceptGate: () -> Bool = { false }

    private var observerTap: CFMachPort?
    private var observerSource: CFRunLoopSource?
    private var acceptTap: CFMachPort?
    private var acceptSource: CFRunLoopSource?

    private(set) var isRunning = false
    private(set) var isAcceptActive = false

    /// Installs the listen-only observer tap. Returns false if the OS refuses
    /// (Input Monitoring not granted).
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: cotypingObserverCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        observerTap = tap
        observerSource = source
        isRunning = true
        return true
    }

    func stop() {
        setAcceptActive(false)
        teardown(tap: &observerTap, source: &observerSource)
        isRunning = false
    }

    /// Installs/removes the consuming accept tap. The coordinator turns it on
    /// only while a suggestion is visible, so cotyping sits in the synchronous
    /// keystroke path for the briefest possible window.
    func setAcceptActive(_ active: Bool) {
        guard active != isAcceptActive else { return }
        if active {
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: cotypingAcceptCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            acceptTap = tap
            acceptSource = source
            isAcceptActive = true
        } else {
            isAcceptActive = false
            // Defer the port teardown one runloop hop: setAcceptActive(false) is
            // reached from inside the accept tap's own callback (a suggestion was
            // just accepted or invalidated), and invalidating a CFMachPort from
            // within its callback is unsafe. Deferring also lets a synthetic insert
            // drain before the tap dies.
            let tap = acceptTap
            let source = acceptSource
            acceptTap = nil
            acceptSource = nil
            DispatchQueue.main.async {
                if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
                if let tap {
                    CGEvent.tapEnable(tap: tap, enable: false)
                    CFMachPortInvalidate(tap)
                }
            }
        }
    }

    private func teardown(tap: inout CFMachPort?, source: inout CFRunLoopSource?) {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
    }

    // MARK: - Callback bodies (always on the main run loop)

    fileprivate func handleObserver(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let observerTap { CGEvent.tapEnable(tap: observerTap, enable: true) }
            return
        }
        guard type == .keyDown, !CotypingSyntheticMarker.isSynthetic(event) else { return }
        onKey?(Self.classify(event))
    }

    /// Returns `true` to swallow the key.
    fileprivate func handleAccept(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let acceptTap { CGEvent.tapEnable(tap: acceptTap, enable: true) }
            return false
        }
        guard type == .keyDown, !CotypingSyntheticMarker.isSynthetic(event) else { return false }
        guard Self.isPlainTab(event), acceptGate() else { return false }
        return onAcceptKey?() ?? false
    }

    // MARK: - Classification

    static func classify(_ event: CGEvent) -> CotypingKeyKind {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return .shortcut }
        switch keyCode {
        case 48: return .acceptance                 // Tab
        case 53, 36, 76: return .dismissal          // Esc, Return, Keypad Enter
        case 123, 124, 125, 126: return .navigation // arrows
        case 51, 117: return .textMutation          // Backspace, Forward Delete
        default:
            let chars = characters(from: event)
            if !chars.isEmpty, chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) {
                return .textMutation
            }
            return .other
        }
    }

    /// Plain Tab — no Command/Control/Option/Shift.
    static func isPlainTab(_ event: CGEvent) -> Bool {
        guard Int(event.getIntegerValueField(.keyboardEventKeycode)) == 48 else { return false }
        let flags = event.flags
        return !flags.contains(.maskCommand) && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate) && !flags.contains(.maskShift)
    }

    static func characters(from event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: buffer, count: min(length, buffer.count))
    }
}

// MARK: - C event-tap callbacks

private func cotypingObserverCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let monitor = Unmanaged<CotypingInputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        MainActor.assumeIsolated { monitor.handleObserver(type: type, event: event) }
    }
    return Unmanaged.passUnretained(event)
}

private func cotypingAcceptCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<CotypingInputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { monitor.handleAccept(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
