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

    func stop() {
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
        isRunning = false
    }

    /// Returns true when the original event should be swallowed.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == .keyDown || type == .keyUp else { return false }

        let shortcut = shortcutProvider()
        let isMatchingShortcut = shortcut.matches(event)
        let isHeldShortcutRelease = shortcutIsDown && type == .keyUp && shortcut.matchesKeyCode(event)
        guard isMatchingShortcut || isHeldShortcutRelease else { return false }

        switch triggerModeProvider() {
        case .pushToTalk:
            if type == .keyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !shortcutIsDown && !isRepeat {
                    shortcutIsDown = true
                    onStart?()
                }
            } else {
                if shortcutIsDown {
                    shortcutIsDown = false
                    onStop?()
                }
            }
        case .toggle:
            if type == .keyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !shortcutIsDown && !isRepeat {
                    shortcutIsDown = true
                    onToggle?()
                }
            } else {
                shortcutIsDown = false
            }
        }
        return true
    }
}

private func dictationShortcutCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<DictationInputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
