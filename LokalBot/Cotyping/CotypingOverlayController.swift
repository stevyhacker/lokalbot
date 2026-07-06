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
    private(set) var acceptanceText: String?
    private let sampler = CotypingBackgroundSampler()
    private var sampleGeneration = 0
    private var samplingInFlight = false
    private var fontStabilizer = CotypingGhostFontSizeStabilizer()
    private var lastInlineRender: InlineRenderState?

    private struct InlineRenderState {
        var text: String
        var frame: CGRect
        var sourceStyle: CotypingFieldStyle?
        var renderStyle: CotypingFieldStyle?
        var lineHeight: CGFloat
        var lineCount: Int
        var visibleFrame: CGRect?
        var inputFrameRect: CGRect?
        var caretIsExact: Bool
        var backgroundLuminance: CGFloat?
    }

    func show(
        text: String,
        caretRect: CGRect,
        inputFrameRect: CGRect? = nil,
        focusIdentityKey: String? = nil,
        style: CotypingFieldStyle? = nil,
        placement: CotypingOverlayPlacement = .inlineDefault,
        acceptanceText: String? = nil,
        isRightToLeft: Bool = false
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
        let visible = screenVisibleFrame(containing: caretRect)
        let stabilizedCaretHeight = fontStabilizer.stabilizedCaretHeight(
            caretRect.height,
            focusSessionKey: Self.fontSessionKey(
                focusIdentityKey: focusIdentityKey,
                inputFrameRect: inputFrameRect,
                caretRect: caretRect))
        let renderStyle = CotypingGhostFontSizing.renderStyle(
            from: style,
            caretHeight: stabilizedCaretHeight,
            caretIsExact: placement.caretIsExact)
        let mirrorLayout = mode.isMirror
            ? CotypingGhostTextLayout.mirrorLayout(text: text, style: renderStyle, visible: visible)
            : nil
        let inlineLayout = mode == .inline
            ? CotypingInlineGhostLayout.make(
                text: text,
                caretRect: caretRect,
                inputFrameRect: inputFrameRect,
                style: renderStyle,
                visible: visible,
                isRightToLeft: isRightToLeft)
            : nil
        let displayText = mirrorLayout?.displayText ?? text
        // Inline ghosts contrast against the real host pixels (sampled below);
        // mirror sits on its own pill, so it keeps the appearance-based color.
        let cachedLuminance = mode.isMirror ? nil : sampler.cachedLuminance(forApp: bundleID)
        hosting.rootView = CotypingGhostView(
            text: displayText, style: renderStyle, showsChrome: mode.isMirror,
            inlineLayout: inlineLayout,
            backgroundLuminance: cachedLuminance)
        hosting.layoutSubtreeIfNeeded()

        let fitting = hosting.fittingSize
        let measured = CotypingGhostStyle.measuredTextSize(text, style: renderStyle)

        // Inline placement tracks the ghost text's own line box centered on the
        // caret's vertical center — never the host caret height, which differs
        // between AppKit (AXBoundsForRange) and WebKit/Chromium
        // (AXBoundsForTextMarkerRange) providers — so vertical alignment stays
        // consistent across apps. Mirror keeps its chrome pill one line below.
        let frame: CGRect
        switch mode {
        case .inline:
            let font = CotypingGhostStyle.resolvedFont(from: renderStyle)
            let lineHeight = inlineLayout?.lineHeight ?? ceil(font.ascender - font.descender)
            if let inlineLayout {
                let estimatedContent = CotypingInlineGhostLayout.estimatedContentSize(
                    for: inlineLayout,
                    style: renderStyle)
                let contentSize = CGSize(
                    width: max(fitting.width, estimatedContent.width),
                    height: max(fitting.height, estimatedContent.height))
                frame = inlineLayout.panelFrame(
                    for: contentSize,
                    caretRect: caretRect,
                    visible: visible)
            } else {
                let textSize = CGSize(
                    width: max(fitting.width, measured.width),
                    height: max(fitting.height, measured.height))
                frame = CotypingOverlayGeometry.inlineFrame(
                    caret: caretRect, textSize: textSize,
                    lineHeight: lineHeight, visible: visible)
            }
            lastInlineRender = InlineRenderState(
                text: text, frame: frame.integral, sourceStyle: style, renderStyle: renderStyle,
                lineHeight: lineHeight,
                lineCount: inlineLayout?.lines.count ?? 1,
                visibleFrame: visible, inputFrameRect: inputFrameRect,
                caretIsExact: placement.caretIsExact,
                backgroundLuminance: cachedLuminance)
        case .mirror:
            let mirrorSize = mirrorLayout?.textSize ?? measured
            let content = CGSize(
                width: max(fitting.width, mirrorSize.width + 16),
                height: max(fitting.height, mirrorSize.height + 8))
            frame = CotypingOverlayGeometry.mirrorFrame(
                caret: caretRect, content: content, visible: visible)
            lastInlineRender = nil
        }
        guard frame.origin.x.isFinite, frame.origin.y.isFinite else { hide(); return }

        panel.setFrame(frame.integral, display: true)
        panel.hasShadow = mode.isMirror
        panel.orderFrontRegardless()
        isVisible = true
        self.acceptanceText = acceptanceText ?? text
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
                    text: text, style: renderStyle, showsChrome: false,
                    inlineLayout: inlineLayout,
                    backgroundLuminance: luminance)
                self.lastInlineRender?.backgroundLuminance = luminance
            }
        }
    }

    /// Slides a visible inline ghost by the accepted text width, avoiding the
    /// short AX re-anchor jitter after word-by-word acceptance.
    @discardableResult
    func advanceInline(
        to remainingText: String,
        insertedText: String,
        isRightToLeft: Bool = false
    ) -> Bool {
        guard isVisible,
              !isRightToLeft,
              !remainingText.isEmpty,
              !insertedText.isEmpty,
              var render = lastInlineRender,
              render.lineCount == 1,
              let hosting,
              render.text.hasPrefix(insertedText),
              String(render.text.dropFirst(insertedText.count)) == remainingText else {
            return false
        }
        let renderedInsertedSize = CotypingGhostStyle.measuredTextSize(insertedText, style: render.renderStyle)
        let hostInsertedWidth = render.caretIsExact
            ? CotypingInsertedTextAdvance.width(of: insertedText, style: render.sourceStyle)
            : nil
        let insertedSize = CGSize(
            width: ceil(hostInsertedWidth ?? renderedInsertedSize.width),
            height: renderedInsertedSize.height)
        hosting.rootView = CotypingGhostView(
            text: remainingText, style: render.renderStyle, showsChrome: false,
            backgroundLuminance: render.backgroundLuminance)
        hosting.layoutSubtreeIfNeeded()
        let remainingMeasured = CotypingGhostStyle.measuredTextSize(remainingText, style: render.renderStyle)
        let remainingSize = CGSize(
            width: max(hosting.fittingSize.width, remainingMeasured.width),
            height: max(hosting.fittingSize.height, remainingMeasured.height))
        guard let advancedFrame = CotypingOverlayGeometry.advancedInlineFrame(
            from: render.frame, insertedTextSize: insertedSize,
            remainingTextSize: remainingSize, lineHeight: render.lineHeight,
            visible: render.visibleFrame)
        else {
            return false
        }

        sampleGeneration += 1
        panel?.setFrame(advancedFrame.integral, display: true)
        render.text = remainingText
        render.frame = advancedFrame.integral
        lastInlineRender = render
        acceptanceText = remainingText
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
        millisecondsSinceLastAcceptance: Int?,
        inputFrameRect: CGRect? = nil,
        isRightToLeft: Bool = false
    ) -> Bool {
        guard isVisible,
              placement.mode == .inline,
              let render = lastInlineRender,
              render.text == text,
              render.sourceStyle == style else {
            return false
        }
        let visible = screenVisibleFrame(containing: caretRect)
        let layout = CotypingInlineGhostLayout.make(
            text: text,
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            style: render.renderStyle,
            visible: visible,
            isRightToLeft: isRightToLeft)
        let targetSize = CotypingInlineGhostLayout.estimatedContentSize(
            for: layout,
            style: render.renderStyle)
        let target = layout.panelFrame(
            for: targetSize,
            caretRect: caretRect,
            visible: visible).integral
        return CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: render.frame,
            targetFrame: target,
            millisecondsSinceLastAcceptance: millisecondsSinceLastAcceptance,
            isRightToLeft: isRightToLeft)
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        acceptanceText = nil
        lastInlineRender = nil
    }

    private static func fontSessionKey(
        focusIdentityKey: String?,
        inputFrameRect: CGRect?,
        caretRect: CGRect
    ) -> String {
        if let focusIdentityKey, !focusIdentityKey.isEmpty {
            return focusIdentityKey
        }
        if let rect = inputFrameRect?.integral {
            return "frame:\(Int(rect.minX)):\(Int(rect.minY)):\(Int(rect.width)):\(Int(rect.height))"
        }
        let rect = caretRect.integral
        return "caret:\(Int(rect.minX)):\(Int(rect.minY))"
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
