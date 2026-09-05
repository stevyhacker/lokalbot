import AppKit
import SwiftUI

/// SwiftUI labels a column's content, but macOS also exposes the native split
/// item's hosting view as a separate group. Name that boundary without
/// replacing the native split view, its children, or its keyboard behavior.
private struct SplitPaneAccessibility: NSViewRepresentable {
    let label: String

    func makeNSView(context: Context) -> PaneAnchor {
        let anchor = PaneAnchor()
        anchor.setAccessibilityElement(false)
        anchor.label = label
        return anchor
    }

    func updateNSView(_ anchor: PaneAnchor, context: Context) {
        anchor.label = label
        anchor.updatePaneLabel()
    }

    final class PaneAnchor: NSView {
        var label = ""

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updatePaneLabel()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            updatePaneLabel()
        }

        func updatePaneLabel() {
            // Defer until SwiftUI has attached the hosting view to its split
            // item. Only this anchor's nearest pane is ever modified.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                var child: NSView = self
                while let parent = child.superview {
                    if parent is NSSplitView {
                        child.setAccessibilityLabel(self.label)
                        return
                    }
                    child = parent
                }
            }
        }
    }
}

extension View {
    func splitPaneAccessibilityLabel(_ label: String) -> some View {
        background { SplitPaneAccessibility(label: label) }
    }
}
