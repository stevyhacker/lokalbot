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

    func show(
        text: String,
        caretRect: CGRect,
        style: CotypingFieldStyle? = nil,
        placement: CotypingOverlayPlacement = .inlineDefault
    ) {
        guard !text.isEmpty,
              caretRect.origin.x.isFinite, caretRect.origin.y.isFinite,
              caretRect.width.isFinite, caretRect.height.isFinite else {
            hide()
            return
        }
        let panel = ensurePanel()
        guard let hosting else { return }
        let mode = placement.mode
        hosting.rootView = CotypingGhostView(text: text, style: style, showsChrome: mode.isMirror)
        hosting.layoutSubtreeIfNeeded()

        let fitting = hosting.fittingSize
        let measured = CotypingGhostStyle.measuredTextSize(text, style: style)
        let chromePadding = mode.isMirror ? CGSize(width: 16, height: 8) : .zero
        let height = max(fitting.height, measured.height + chromePadding.height, caretRect.height > 1 ? caretRect.height : 18)
        let width = max(fitting.width, measured.width + chromePadding.width, 8)
        let visible = screenVisibleFrame(containing: caretRect)

        // Inline: anchor to the caret's right edge, vertically centered. Clamp X
        // so a long suggestion never renders past the screen's right edge (it
        // shifts left rather than overflowing), and keep Y on-screen.
        // Mirror: the caret is mid-line or its geometry is unreliable, so there is
        // no inline home — render the popup one line below the caret (flipped
        // above if there is no room below).
        let frame: CGRect
        switch mode {
        case .inline:
            var x = caretRect.maxX + 2
            if let visible, x + width > visible.maxX {
                x = max(visible.minX + 2, visible.maxX - width - 2)
            }
            // AX caret rects are line boxes, while bare SwiftUI text paints near
            // the top of its panel. Shift inline text down toward the host
            // baseline; popup mode has its own chrome and line-below placement.
            let baselineOffset = min(max(caretRect.height * 0.75, 5), 12)
            var y = caretRect.midY - height / 2 - baselineOffset
            if let visible, y < visible.minY { y = visible.minY + 2 }
            frame = CGRect(x: x, y: y, width: width, height: height)
        case .mirror:
            var x = min(caretRect.minX, (visible?.maxX ?? caretRect.minX) - width)
            if let visible { x = max(visible.minX + 2, x) }
            var y = caretRect.minY - height - 2
            if let visible, y < visible.minY { y = caretRect.maxY + 2 }
            frame = CGRect(x: x, y: y, width: width, height: height)
        }
        guard frame.origin.x.isFinite, frame.origin.y.isFinite else { hide(); return }

        panel.setFrame(frame.integral, display: true)
        panel.hasShadow = mode.isMirror
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    /// Visible frame of the screen containing `rect`, or nil if none matches.
    private func screenVisibleFrame(containing rect: CGRect) -> CGRect? {
        let point = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
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
        panel.hasShadow = false
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

/// The inline ghost text. Keep this visually close to host text instead of a
/// separate popup pill; CotypingRenderMode controls when popup placement is
/// necessary.
struct CotypingGhostView: View {
    let text: String
    var style: CotypingFieldStyle? = nil
    var showsChrome = false

    /// Matches the host field's font family at a clamped size; falls back to the
    /// system font at the field's (clamped) size — never a fixed 13 pt.
    private var font: Font {
        if let nsFont = CotypingGhostStyle.font(from: style) { return Font(nsFont) }
        return .system(size: CotypingGhostStyle.clampedPointSize(style?.fontPointSize))
    }
    /// Dimmed host text color so the ghost reads as a suggestion; falls back to
    /// the secondary label color.
    private var color: Color {
        if let nsColor = CotypingGhostStyle.ghostColor(from: style) { return Color(nsColor: nsColor) }
        return Color(nsColor: .secondaryLabelColor)
    }

    @ViewBuilder
    var body: some View {
        if showsChrome {
            textView
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
        } else {
            textView
        }
    }

    private var textView: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize()
    }
}
