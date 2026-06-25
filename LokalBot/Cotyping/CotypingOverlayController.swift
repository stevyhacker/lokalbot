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
        let visible = screenVisibleFrame(containing: caretRect)

        // Inline placement tracks the ghost text's own line box centered on the
        // caret's vertical center — never the host caret height, which differs
        // between AppKit (AXBoundsForRange) and WebKit/Chromium
        // (AXBoundsForTextMarkerRange) providers — so vertical alignment stays
        // consistent across apps. Mirror keeps its chrome pill one line below.
        let frame: CGRect
        switch mode {
        case .inline:
            let font = CotypingGhostStyle.resolvedFont(from: style)
            let textSize = CGSize(
                width: max(fitting.width, measured.width),
                height: max(fitting.height, measured.height))
            frame = CotypingOverlayGeometry.inlineFrame(
                caret: caretRect, textSize: textSize,
                lineHeight: ceil(font.ascender - font.descender), visible: visible)
        case .mirror:
            let content = CGSize(
                width: max(fitting.width, measured.width + 16),
                height: max(fitting.height, measured.height + 8))
            frame = CotypingOverlayGeometry.mirrorFrame(
                caret: caretRect, content: content, visible: visible)
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
    /// The ghost color as a concrete sRGB color, so it paints identically no
    /// matter what appearance the borderless overlay panel resolves to (an
    /// agent-app panel does not reliably inherit dark mode). Derived from the
    /// host field's own colors, falling back to the system appearance only when
    /// the field reports none.
    private var color: Color {
        Color(nsColor: CotypingGhostStyle.resolvedGhostColor(
            from: style, isDarkEnvironment: Self.prefersDarkEnvironment))
    }

    /// Whether the system is in dark mode, read from the global setting rather
    /// than the panel's own (unreliable) appearance. Only consulted when the host
    /// field reports no colors to derive from.
    private static var prefersDarkEnvironment: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
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

/// Pure placement math for the ghost overlay, split out from `show()` so the
/// frame geometry is deterministic and unit-testable. All rects are in global
/// Cocoa (bottom-left origin) coordinates.
nonisolated enum CotypingOverlayGeometry {
    /// Gap between the caret and the suggestion / screen edges.
    static let gap: CGFloat = 2

    /// Inline ghost frame: the suggestion sits just right of the caret with its
    /// line box centered on the caret's vertical center. The panel height tracks
    /// the ghost text's own line height — never the host caret height, which
    /// varies between AppKit (`AXBoundsForRange`) and WebKit/Chromium
    /// (`AXBoundsForTextMarkerRange`) providers — so vertical placement is
    /// consistent across apps. Clamps to the visible frame's right/bottom edges.
    static func inlineFrame(
        caret: CGRect, textSize: CGSize, lineHeight: CGFloat, visible: CGRect?
    ) -> CGRect {
        let height = max(textSize.height, lineHeight, 1)
        let width = max(textSize.width, 8)
        var x = caret.maxX + gap
        if let visible, x + width > visible.maxX {
            x = max(visible.minX + gap, visible.maxX - width - gap)
        }
        var y = caret.midY - height / 2
        if let visible, y < visible.minY { y = visible.minY + gap }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Mirror (popup) frame: a chrome pill one line below the caret, flipped
    /// above when there is no room below. Used for mid-line carets where inline
    /// text would paint over the host's trailing characters.
    static func mirrorFrame(
        caret: CGRect, content: CGSize, visible: CGRect?
    ) -> CGRect {
        let width = max(content.width, 8)
        let height = max(content.height, 18)
        var x = min(caret.minX, (visible?.maxX ?? caret.minX) - width)
        if let visible { x = max(visible.minX + gap, x) }
        var y = caret.minY - height - gap
        if let visible, y < visible.minY { y = caret.maxY + gap }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
