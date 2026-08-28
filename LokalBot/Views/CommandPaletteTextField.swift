import AppKit
import SwiftUI

/// A narrow AppKit bridge for the command palette's editor. The palette needs
/// one responder to own both text insertion and navigation commands; combining
/// SwiftUI's text-field bridge with ancestor `onKeyPress` handlers can deliver
/// the same printable key through two input paths on macOS.
struct CommandPaletteTextField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let onSubmit: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> PaletteTextField {
        let field = PaletteTextField()
        field.delegate = context.coordinator
        field.stringValue = text
        field.placeholderString = "Type a command or search meetings…"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityIdentifier("palette.input")
        field.setAccessibilityLabel("Command palette input")
        field.requestFocus()
        return field
    }

    func updateNSView(_ field: PaletteTextField, context: Context) {
        context.coordinator.update(parent: self)
        if field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.consumeFocusRequest(focusRequest) {
            field.requestFocus()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        private var onSubmit: () -> Void
        private var onPrevious: () -> Void
        private var onNext: () -> Void
        private var onCancel: () -> Void
        private var lastFocusRequest: Int

        init(parent: CommandPaletteTextField) {
            text = parent.$text
            onSubmit = parent.onSubmit
            onPrevious = parent.onPrevious
            onNext = parent.onNext
            onCancel = parent.onCancel
            lastFocusRequest = parent.focusRequest
        }

        func update(parent: CommandPaletteTextField) {
            text = parent.$text
            onSubmit = parent.onSubmit
            onPrevious = parent.onPrevious
            onNext = parent.onNext
            onCancel = parent.onCancel
        }

        func consumeFocusRequest(_ request: Int) -> Bool {
            guard request != lastFocusRequest else { return false }
            lastFocusRequest = request
            return true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  text.wrappedValue != field.stringValue else { return }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                onSubmit()
            case #selector(NSResponder.moveUp(_:)):
                onPrevious()
            case #selector(NSResponder.moveDown(_:)):
                onNext()
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
            default:
                return false
            }
            return true
        }
    }
}

final class PaletteTextField: NSTextField {
    func requestFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window else { return }
            if let editor = currentEditor(), window.firstResponder === editor {
                return
            }
            window.makeFirstResponder(self)
        }
    }
}
