import AppKit
import ApplicationServices

/// Invalidate observations even when an app/tab switches away and back between
/// two polls. Polling still validates the source when AX notifications are absent.
final class MeetingSpeakerSourceMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var observer: AXObserver?
    private var activation: NSObjectProtocol?
    private var processID: pid_t?
    var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return epoch }
    private func invalidate() { lock.lock(); epoch &+= 1; lock.unlock() }

    @MainActor func start(processID: pid_t) {
        guard self.processID != processID else { return }
        stop()
        self.processID = processID
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                self?.invalidate()
            }
        var created: AXObserver?
        let status = AXObserverCreate(processID, { _, _, _, context in
            guard let context else { return }
            Unmanaged<MeetingSpeakerSourceMonitor>.fromOpaque(context).takeUnretainedValue().invalidate()
        }, &created)
        guard status == .success, let created else { return }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.012)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification, kAXSelectedChildrenChangedNotification] {
            AXObserverAddNotification(created, app, name as CFString, context)
        }
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            AXObserverAddNotification(created, focused as! AXUIElement, kAXTitleChangedNotification as CFString, context)
        }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    @MainActor func stop() {
        invalidate()
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        processID = nil
    }

    deinit {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
    }
}
