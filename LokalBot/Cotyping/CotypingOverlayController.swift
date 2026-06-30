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
    private let sampler = CotypingBackgroundSampler()
    private var sampleGeneration = 0
    private var samplingInFlight = false
    private var lastInlineRender: InlineRenderState?

    private struct InlineRenderState {
        var text: String
        var frame: CGRect
        var style: CotypingFieldStyle?
        var lineHeight: CGFloat
        var visibleFrame: CGRect?
        var backgroundLuminance: CGFloat?
    }

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
        sampleGeneration += 1
        let generation = sampleGeneration
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Inline ghosts contrast against the real host pixels (sampled below);
        // mirror sits on its own pill, so it keeps the appearance-based color.
        let cachedLuminance = mode.isMirror ? nil : sampler.cachedLuminance(forApp: bundleID)
        hosting.rootView = CotypingGhostView(
            text: text, style: style, showsChrome: mode.isMirror, backgroundLuminance: cachedLuminance)
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
            let lineHeight = ceil(font.ascender - font.descender)
            let textSize = CGSize(
                width: max(fitting.width, measured.width),
                height: max(fitting.height, measured.height))
            frame = CotypingOverlayGeometry.inlineFrame(
                caret: caretRect, textSize: textSize,
                lineHeight: lineHeight, visible: visible)
            lastInlineRender = InlineRenderState(
                text: text, frame: frame.integral, style: style, lineHeight: lineHeight,
                visibleFrame: visible, backgroundLuminance: cachedLuminance)
        case .mirror:
            let content = CGSize(
                width: max(fitting.width, measured.width + 16),
                height: max(fitting.height, measured.height + 8))
            frame = CotypingOverlayGeometry.mirrorFrame(
                caret: caretRect, content: content, visible: visible)
            lastInlineRender = nil
        }
        guard frame.origin.x.isFinite, frame.origin.y.isFinite else { hide(); return }

        panel.setFrame(frame.integral, display: true)
        panel.hasShadow = mode.isMirror
        panel.orderFrontRegardless()
        isVisible = true
        // First suggestion in this app (no cached luminance): sample the real
        // background asynchronously and refine the color. The generation token
        // drops stale captures; the in-flight guard avoids a capture storm.
        if !mode.isMirror, cachedLuminance == nil, !samplingInFlight {
            samplingInFlight = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.samplingInFlight = false }
                let luminance = await self.sampler.sampleLuminance(at: caretRect, forApp: bundleID)
                guard generation == self.sampleGeneration, self.isVisible,
                      let hosting = self.hosting, let luminance else { return }
                hosting.rootView = CotypingGhostView(
                    text: text, style: style, showsChrome: false, backgroundLuminance: luminance)
                self.lastInlineRender?.backgroundLuminance = luminance
            }
        }
    }

    /// Slides a visible inline ghost by the accepted text width, avoiding the
    /// short AX re-anchor jitter after word-by-word acceptance.
    @discardableResult
    func advanceInline(to remainingText: String, insertedText: String) -> Bool {
        guard isVisible,
              !remainingText.isEmpty,
              !insertedText.isEmpty,
              var render = lastInlineRender,
              let hosting,
              render.text.hasPrefix(insertedText),
              String(render.text.dropFirst(insertedText.count)) == remainingText else {
            return false
        }
        let insertedSize = CotypingGhostStyle.measuredTextSize(insertedText, style: render.style)
        let remainingSize = CotypingGhostStyle.measuredTextSize(remainingText, style: render.style)
        guard let advancedFrame = CotypingOverlayGeometry.advancedInlineFrame(
            from: render.frame, insertedTextSize: insertedSize,
            remainingTextSize: remainingSize, lineHeight: render.lineHeight,
            visible: render.visibleFrame)
        else {
            return false
        }

        sampleGeneration += 1
        hosting.rootView = CotypingGhostView(
            text: remainingText, style: render.style, showsChrome: false,
            backgroundLuminance: render.backgroundLuminance)
        hosting.layoutSubtreeIfNeeded()

        panel?.setFrame(advancedFrame.integral, display: true)
        render.text = remainingText
        render.frame = advancedFrame.integral
        lastInlineRender = render
        return true
    }

    /// Returns true when a delayed post-accept AX refresh should keep the
    /// current inline geometry instead of re-presenting against likely stale
    /// host caret coordinates.
    func shouldHoldInlineReanchor(
        text: String,
        caretRect: CGRect,
        style: CotypingFieldStyle?,
        placement: CotypingOverlayPlacement,
        millisecondsSinceLastAcceptance: Int?
    ) -> Bool {
        guard isVisible,
              placement.mode == .inline,
              let render = lastInlineRender,
              render.text == text,
              render.style == style else {
            return false
        }
        let measured = CotypingGhostStyle.measuredTextSize(text, style: style)
        let target = CotypingOverlayGeometry.inlineFrame(
            caret: caretRect,
            textSize: measured,
            lineHeight: render.lineHeight,
            visible: screenVisibleFrame(containing: caretRect)).integral
        return CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: render.frame,
            targetFrame: target,
            millisecondsSinceLastAcceptance: millisecondsSinceLastAcceptance)
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        lastInlineRender = nil
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
        // Keep our ephemeral ghost out of screenshots, recordings, and our own
        // background sampling.
        panel.sharingType = .none

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
    /// Average luminance (0…1) of the host pixels behind the ghost, sampled from
    /// the screen when available; lets the color contrast with the real
    /// background instead of guessing from AX/appearance.
    var backgroundLuminance: CGFloat? = nil

    /// Matches the host field's font family at a clamped size; falls back to the
    /// system font at the field's (clamped) size — never a fixed 13 pt.
    private var font: Font {
        if let nsFont = CotypingGhostStyle.font(from: style) { return Font(nsFont) }
        return .system(size: CotypingGhostStyle.clampedPointSize(style?.fontPointSize))
    }
    /// The ghost color as a concrete sRGB color, so it paints identically no
    /// matter what appearance the borderless overlay panel resolves to. Contrasts
    /// against the real background sampled from the screen (`backgroundLuminance`)
    /// when available, else the host field's colors / system appearance.
    private var color: Color {
        Color(nsColor: CotypingGhostStyle.resolvedGhostColor(
            from: style, isDarkEnvironment: Self.prefersDarkEnvironment,
            measuredLuminance: backgroundLuminance))
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
    static let reanchorDriftTolerance: CGFloat = 6
    static let backwardDriftHoldWindowMilliseconds = 300

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

    /// Frame for a same-line inline ghost after accepting its leading text. The
    /// caller falls back to a fresh caret anchor when the slide would overflow.
    static func advancedInlineFrame(
        from frame: CGRect,
        insertedTextSize: CGSize,
        remainingTextSize: CGSize,
        lineHeight: CGFloat,
        visible: CGRect?
    ) -> CGRect? {
        let shift = insertedTextSize.width
        guard shift.isFinite, shift > 0,
              frame.origin.x.isFinite, frame.origin.y.isFinite else {
            return nil
        }
        let height = max(remainingTextSize.height, lineHeight, 1)
        let width = max(remainingTextSize.width, 8)
        var advanced = CGRect(
            x: frame.minX + shift,
            y: frame.midY - height / 2,
            width: width,
            height: height)
        if let visible {
            guard advanced.minX >= visible.minX + gap,
                  advanced.maxX <= visible.maxX - gap else {
                return nil
            }
            if advanced.minY < visible.minY {
                advanced.origin.y = visible.minY + gap
            }
        }
        return advanced
    }

    /// CoTabby-style post-accept stability rule for inline ghosts. Hold small
    /// same-text drift, and briefly hold larger backward jumps because AX often
    /// publishes inserted text before its caret frames catch up.
    static func shouldHoldInlineReanchor(
        currentFrame: CGRect,
        targetFrame: CGRect,
        millisecondsSinceLastAcceptance: Int?,
        isRightToLeft: Bool = false
    ) -> Bool {
        let deltaY = targetFrame.origin.y - currentFrame.origin.y
        guard abs(deltaY) <= reanchorDriftTolerance else { return false }

        let deltaX = targetFrame.origin.x - currentFrame.origin.x
        if abs(deltaX) <= reanchorDriftTolerance {
            return true
        }
        let isBackward = isRightToLeft
            ? deltaX > reanchorDriftTolerance
            : deltaX < -reanchorDriftTolerance
        let insideHoldWindow = millisecondsSinceLastAcceptance
            .map { $0 <= backwardDriftHoldWindowMilliseconds } ?? false
        return isBackward && insideHoldWindow
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
