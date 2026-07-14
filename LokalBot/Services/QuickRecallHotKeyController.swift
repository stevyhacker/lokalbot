import Carbon.HIToolbox
import Foundation

/// Registers LokalBot's opt-in, system-wide Quick Recall shortcut without an
/// event tap. Carbon hot keys work while another app is focused and do not read
/// or retain any other keyboard input.
@MainActor
final class QuickRecallHotKeyController {
    static let shortcutLabel = "⌃⇧Space"

    var onInvoke: (() -> Void)?

    private static let signature: OSType = 0x4C425152 // "LBQR"
    private static let identifier: UInt32 = 1

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            unregister()
            return true
        }
        guard hotKey == nil else { return true }
        guard installHandlerIfNeeded() else { return false }

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: Self.identifier)
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference)
        guard status == noErr else { return false }
        hotKey = reference
        return true
    }

    func stop() {
        unregister()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    fileprivate func invokeIfMatching(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        var actualSize = 0
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            &actualSize,
            &hotKeyID)
        guard status == noErr,
              hotKeyID.signature == Self.signature,
              hotKeyID.id == Self.identifier else {
            return OSStatus(eventNotHandledErr)
        }
        onInvoke?()
        return noErr
    }

    private func installHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            quickRecallHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler)
        guard status == noErr else { return false }
        eventHandler = handler
        return true
    }

    private func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
    }
}

private func quickRecallHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let controller = Unmanaged<QuickRecallHotKeyController>
        .fromOpaque(userData)
        .takeUnretainedValue()
    return MainActor.assumeIsolated {
        controller.invokeIfMatching(event)
    }
}
