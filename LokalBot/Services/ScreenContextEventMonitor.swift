import AppKit
import Foundation

/// Converts coarse interaction boundaries into capture hints. It never reads a
/// key code, typed string, mouse location, or clipboard contents; only the fact
/// that typing/scrolling/clicking/copying settled is retained as a trigger name.
@MainActor
final class ScreenContextEventMonitor {
    var onTrigger: ((ScreenCaptureTrigger) -> Void)?

    private var globalMonitor: Any?
    private var pasteboardTimer: Timer?
    private var typingWork: DispatchWorkItem?
    private var scrollWork: DispatchWorkItem?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp, .keyDown, .scrollWheel]
        ) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPasteboardBoundary() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pasteboardTimer = timer
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
        typingWork?.cancel()
        typingWork = nil
        scrollWork?.cancel()
        scrollWork = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            typingWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.onTrigger?(.typingPause) }
            }
            typingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        case .scrollWheel:
            scrollWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.onTrigger?(.scrollSettled) }
            }
            scrollWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            onTrigger?(.click)
        default:
            break
        }
    }

    private func checkPasteboardBoundary() {
        let current = NSPasteboard.general.changeCount
        guard current != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = current
        onTrigger?(.clipboardChange)
    }
}
