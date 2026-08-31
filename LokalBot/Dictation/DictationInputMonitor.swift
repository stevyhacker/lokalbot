import CoreGraphics
import Foundation

/// Global shortcut watcher for Handy-style dictation. It consumes the configured
/// shortcut so the trigger never leaks a stray Space into the focused app.
@MainActor
final class DictationInputMonitor {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onToggle: (() -> Void)?
    var triggerModeProvider: () -> DictationTriggerMode = { .pushToTalk }
    var shortcutProvider: () -> DictationShortcut = { .handyDefault }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var isRunning = false
    private var shortcutIsDown = false
    private var activeTriggerMode: DictationTriggerMode?
    private var activeShortcut: DictationShortcut?

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: dictationShortcutCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isRunning = true
        return true
    }

    func stop(releasingHeldShortcut: Bool = false) {
        let shouldStop = releasingHeldShortcut
            && shortcutIsDown
            && activeTriggerMode == .pushToTalk
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        shortcutIsDown = false
        activeTriggerMode = nil
        activeShortcut = nil
        isRunning = false
        if shouldStop { onStop?() }
    }

    /// Returns true when the original event should be swallowed.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            recoverDisabledTap()
            return false
        }
        guard type == .keyDown || type == .keyUp else { return false }

        let shortcut = shortcutProvider()
        let isMatchingShortcut = shortcut.matches(event)
        let isHeldShortcutRelease = shortcutIsDown
            && type == .keyUp
            && (activeShortcut ?? shortcut).matchesKeyCode(event)
        guard isMatchingShortcut || isHeldShortcutRelease else { return false }

        let triggerMode = type == .keyUp
            ? (activeTriggerMode ?? triggerModeProvider())
            : triggerModeProvider()
        switch triggerMode {
        case .pushToTalk:
            handlePushToTalk(type: type, event: event, shortcut: shortcut)
        case .toggle:
            handleToggle(type: type, event: event, shortcut: shortcut)
        }
        return true
    }

    /// A disabled event tap can swallow the physical key-up. Treat the
    /// notification as a fail-safe release before re-enabling the tap.
    private func recoverDisabledTap() {
        let shouldStop = shortcutIsDown && activeTriggerMode == .pushToTalk
        clearHeldShortcut()
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        if shouldStop { onStop?() }
    }

    private func handlePushToTalk(
        type: CGEventType,
        event: CGEvent,
        shortcut: DictationShortcut
    ) {
        if type == .keyDown {
            guard !shortcutIsDown, !isRepeat(event) else { return }
            shortcutIsDown = true
            activeTriggerMode = .pushToTalk
            activeShortcut = shortcut
            onStart?()
        } else if shortcutIsDown {
            clearHeldShortcut()
            onStop?()
        }
    }

    private func handleToggle(
        type: CGEventType,
        event: CGEvent,
        shortcut: DictationShortcut
    ) {
        guard type == .keyDown else {
            clearHeldShortcut()
            return
        }
        guard !shortcutIsDown, !isRepeat(event) else { return }
        shortcutIsDown = true
        activeTriggerMode = .toggle
        activeShortcut = shortcut
        onToggle?()
    }

    private func clearHeldShortcut() {
        shortcutIsDown = false
        activeTriggerMode = nil
        activeShortcut = nil
    }

    private func isRepeat(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    }
}

private func dictationShortcutCallback(
    _: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<DictationInputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
