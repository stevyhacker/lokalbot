import Carbon.HIToolbox
import Foundation

/// Pure rule for deciding whether the active keyboard input source composes
/// through marked text. Plain keyboard layouts commit directly; non-layout
/// input methods are treated as composing except known direct-ASCII modes.
enum CotypingCompositionInputModeClassifier {
    static let nonComposingInputModeIDs: Set<String> = [
        "com.apple.inputmethod.Roman"
    ]

    static func isComposingInputMode(isKeyboardLayout: Bool?, inputModeID: String?) -> Bool {
        if isKeyboardLayout == true {
            return false
        }
        if let inputModeID, nonComposingInputModeIDs.contains(inputModeID) {
            return false
        }
        return true
    }
}

/// Caches the current Text Input Source composition state so the accept tap can
/// pass IME-owned keys through without touching Carbon at event time.
@MainActor
final class CotypingKeyboardInputSourceMonitor {
    private(set) var isComposingIMEActive = false

    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.selectedInputSourceChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    private static let selectedInputSourceChangedNotification = Notification.Name(
        kTISNotifySelectedKeyboardInputSourceChanged as String
    )

    func refresh() {
        guard let unmanagedSource = TISCopyCurrentKeyboardInputSource() else {
            // Carbon could not prove a direct-input keyboard layout. Fail
            // closed for suggestion ownership so Tab remains with the host.
            isComposingIMEActive = true
            return
        }
        let source = unmanagedSource.takeRetainedValue()
        let inputSourceType = Self.stringProperty(source, kTISPropertyInputSourceType)
        let isKeyboardLayout = inputSourceType.map { $0 == (kTISTypeKeyboardLayout as String) }
        let inputModeID = Self.stringProperty(source, kTISPropertyInputModeID)
        isComposingIMEActive = CotypingCompositionInputModeClassifier.isComposingInputMode(
            isKeyboardLayout: isKeyboardLayout,
            inputModeID: inputModeID)
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
