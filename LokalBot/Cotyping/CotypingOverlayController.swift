import AppKit
import SwiftUI

/// The floating ghost text. Trimmed port of Cotabby's `OverlayController`: one
/// borderless, non-activating, click-through `NSPanel` positioned at the caret
/// in global Cocoa coordinates. It never becomes key/main, so the host app keeps
/// keyboard focus while the suggestion is shown.
@MainActor
final class CotypingOverlayController {
    private var panel: CotypingOverlayPanel?
    private var hosting: NSHostingView<CotypingGhostView>?
    private(set) var isVisible = false

    func show(text: String, caretRect: CGRect) {
        guard !text.isEmpty,
              caretRect.origin.x.isFinite, caretRect.origin.y.isFinite,
              caretRect.width.isFinite, caretRect.height.isFinite else {
            hide()
            return
        }
        let panel = ensurePanel()
        guard let hosting else { return }
        hosting.rootView = CotypingGhostView(text: text)
        hosting.layoutSubtreeIfNeeded()

        let fitting = hosting.fittingSize
        let height = max(fitting.height, caretRect.height > 1 ? caretRect.height : 18)
        let width = max(fitting.width, 8)
        let frame = CGRect(
            x: caretRect.maxX + 2,
            y: caretRect.midY - height / 2,
            width: width, height: height)
        guard frame.origin.x.isFinite, frame.origin.y.isFinite else { hide(); return }

        panel.setFrame(frame.integral, display: true)
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    private func ensurePanel() -> CotypingOverlayPanel {
        if let panel { return panel }
        let panel = CotypingOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let hosting = NSHostingView(rootView: CotypingGhostView(text: ""))
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }
}

/// A panel that never steals keyboard focus from the app being typed into.
final class CotypingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The inline ghost text. Renders on an opaque, theme-aware pill (not a
/// translucent material) so it stays legible over any host app's background —
/// the earlier `.regularMaterial.opacity(0.6)` washed the text out. Uses system
/// label/background colors so contrast is correct in both light and dark mode.
struct CotypingGhostView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}
