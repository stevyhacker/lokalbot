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
        if event.keyCode == 48, !hasMarkedText(), !inputSource.isComposingIMEActive,
           modifiers.isEmpty || modifiers == .shift {
            // Once there is no acceptable ghost, this short rehearsal follows
            // the window's key-view loop instead of inserting indentation.
            // Shift-Tab always navigates back; IME composition keeps its keys.
            if modifiers == .shift { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
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
        guard canAccept, let currentContainer = textContainer else { return }
        // Layout the complete sentence so wrapped ghost lines return to the
        // editor's left margin. Drawing into a caret-width rectangle indents
        // every continuation line beneath the insertion point.
        let preview = NSTextStorage(attributedString: attributedString())
        let range = NSRange(location: preview.length, length: (suggestion as NSString).length)
        var attributes = typingAttributes
        attributes[.font] = font ?? NSFont.systemFont(ofSize: 14)
        attributes[.foregroundColor] = NSColor.secondaryLabelColor
        preview.append(NSAttributedString(string: suggestion, attributes: attributes))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: currentContainer.size.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = currentContainer.lineFragmentPadding
        preview.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), at: textContainerOrigin)
    }
}
