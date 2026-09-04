import AppKit
import SwiftUI

/// The native text system owns selection, focus and marked text. SwiftUI owns
/// the committed string and suggestion. Ghost text is painted, never inserted
/// into the editable value until a deliberate acceptance.
struct RehearsalTextEditor: NSViewRepresentable {
    @Binding var text: String
    let suggestion: String
    let acceptKey: CotypingAcceptKey
    let focusRevision: Int
    let onAccept: () -> Void
    let onReject: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = RehearsalNativeTextView()
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 10)
        editor.font = .systemFont(ofSize: 14)
        editor.drawsBackground = false
        editor.delegate = context.coordinator
        editor.setAccessibilityIdentifier("autocomplete.rehearsal.editor")
        editor.setAccessibilityLabel("Autocomplete rehearsal text")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? RehearsalNativeTextView else { return }
        context.coordinator.parent = self
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        editor.suggestion = suggestion
        editor.acceptKey = acceptKey
        editor.onAccept = onAccept
        editor.onReject = onReject
        editor.needsDisplay = true
        if focusRevision > context.coordinator.focusRevision {
            context.coordinator.focusRevision = focusRevision
            DispatchQueue.main.async { [weak editor] in
                guard let editor else { return }
                editor.window?.makeFirstResponder(editor)
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RehearsalTextEditor
        var focusRevision = 0
        init(_ parent: RehearsalTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            if editor.hasMarkedText() { parent.onReject(); return }
            parent.text = editor.string
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? NSTextView)?.needsDisplay = true
        }
    }
}

private final class RehearsalNativeTextView: NSTextView {
    private let inputSource = CotypingKeyboardInputSourceMonitor()
    var suggestion = ""
    var acceptKey: CotypingAcceptKey = .tab
    var onAccept: (() -> Void)?
    var onReject: (() -> Void)?

    private var canAccept: Bool {
        !suggestion.isEmpty && selectedRange().location == (string as NSString).length
            && CotypingAcceptanceSnapshotPolicy.canAccept(
                markedTextState: hasMarkedText() ? .active : .inactive,
                composingInputModeActive: inputSource.isComposingIMEActive,
                hasLiveContent: true, selectionLength: selectedRange().length)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if canAccept, modifiers.isEmpty, event.keyCode == UInt16(acceptKey.rawValue) {
            onAccept?()
            return
        }
        if !hasMarkedText(), event.keyCode == 53, !suggestion.isEmpty {
            onReject?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard canAccept, let window else { return }
        let screenRect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        let caret = convert(window.convertFromScreen(screenRect), from: nil)
        let ghost = NSAttributedString(string: suggestion, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor])
        ghost.draw(with: NSRect(x: caret.minX, y: caret.minY,
                               width: max(0, bounds.width - caret.minX - 10), height: max(20, bounds.height - caret.minY)),
                   options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
