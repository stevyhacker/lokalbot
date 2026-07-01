import AppKit
import QuartzCore
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
        var acceptanceHintLabel: String?
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
        acceptanceHintLabel: String? = nil,
        acceptanceText: String? = nil,
        isRightToLeft: Bool = false,
        fadeIn: Bool = true,
        fadeDurationSeconds: Double = CotypingSuggestionFadeInPolicy.defaultDurationSeconds
    ) {
        guard !text.isEmpty,
              caretRect.origin.x.isFinite, caretRect.origin.y.isFinite,
              caretRect.width.isFinite, caretRect.height.isFinite else {
            hide()
            return
        }
        let panel = ensurePanel()
        guard let hosting else { return }
        let shouldFadeIn = CotypingSuggestionFadeInPolicy.shouldFadeIn(
            isEnabled: fadeIn,
            overlayWasVisible: isVisible,
            reduceMotionEnabled: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        panel.alphaValue = shouldFadeIn ? 0 : 1

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
                acceptanceHintLabel: acceptanceHintLabel,
                isRightToLeft: isRightToLeft)
            : nil
        let displayText = mirrorLayout?.displayText ?? text
        // Inline ghosts contrast against the real host pixels (sampled below);
        // mirror sits on its own pill, so it keeps the appearance-based color.
        let cachedLuminance = mode.isMirror ? nil : sampler.cachedLuminance(forApp: bundleID)
        hosting.rootView = CotypingGhostView(
            text: displayText, style: renderStyle, showsChrome: mode.isMirror,
            acceptanceHintLabel: acceptanceHintLabel, inlineLayout: inlineLayout,
            backgroundLuminance: cachedLuminance)
        hosting.layoutSubtreeIfNeeded()

        let fitting = hosting.fittingSize
        let measured = CotypingGhostStyle.measuredTextSize(text, style: renderStyle)
        let measuredWithHint = CotypingAcceptanceHintLayout.reservedSize(
            for: measured,
            label: acceptanceHintLabel)

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
                    style: renderStyle,
                    acceptanceHintLabel: acceptanceHintLabel)
                let contentSize = CGSize(
                    width: max(fitting.width, estimatedContent.width),
                    height: max(fitting.height, estimatedContent.height))
                frame = inlineLayout.panelFrame(
                    for: contentSize,
                    caretRect: caretRect,
                    visible: visible)
            } else {
                let textSize = CGSize(
                    width: max(fitting.width, measuredWithHint.width),
                    height: max(fitting.height, measuredWithHint.height))
                frame = CotypingOverlayGeometry.inlineFrame(
                    caret: caretRect, textSize: textSize,
                    lineHeight: lineHeight, visible: visible)
            }
            lastInlineRender = InlineRenderState(
                text: text, frame: frame.integral, sourceStyle: style, renderStyle: renderStyle,
                acceptanceHintLabel: acceptanceHintLabel, lineHeight: lineHeight,
                lineCount: inlineLayout?.lines.count ?? 1,
                visibleFrame: visible, inputFrameRect: inputFrameRect,
                caretIsExact: placement.caretIsExact,
                backgroundLuminance: cachedLuminance)
        case .mirror:
            let mirrorSize = mirrorLayout?.textSize ?? measured
            let mirrorSizeWithHint = CotypingAcceptanceHintLayout.reservedSize(
                for: mirrorSize,
                label: acceptanceHintLabel)
            let content = CGSize(
                width: max(fitting.width, mirrorSizeWithHint.width + 16),
                height: max(fitting.height, mirrorSizeWithHint.height + 8))
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
        if shouldFadeIn {
            fadeInPanel(durationSeconds: fadeDurationSeconds)
        }
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
                    acceptanceHintLabel: acceptanceHintLabel, inlineLayout: inlineLayout,
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
            acceptanceHintLabel: render.acceptanceHintLabel,
            backgroundLuminance: render.backgroundLuminance)
        hosting.layoutSubtreeIfNeeded()
        let remainingMeasured = CotypingGhostStyle.measuredTextSize(remainingText, style: render.renderStyle)
        let remainingWithHint = CotypingAcceptanceHintLayout.reservedSize(
            for: remainingMeasured,
            label: render.acceptanceHintLabel)
        let remainingSize = CGSize(
            width: max(hosting.fittingSize.width, remainingWithHint.width),
            height: max(hosting.fittingSize.height, remainingWithHint.height))
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
            acceptanceHintLabel: render.acceptanceHintLabel,
            isRightToLeft: isRightToLeft)
        let targetSize = CotypingInlineGhostLayout.estimatedContentSize(
            for: layout,
            style: render.renderStyle,
            acceptanceHintLabel: render.acceptanceHintLabel)
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

    private func fadeInPanel(durationSeconds: Double) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CotypingSuggestionFadeInPolicy.clampedDurationSeconds(durationSeconds)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = 1
        }
    }
}

/// A panel that never steals keyboard focus from the app being typed into.
final class CotypingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Decides whether a fresh ghost-text panel presentation should fade in.
/// Updates to an already-visible overlay must not animate, or streamed tokens
/// and post-accept reanchors would visibly flicker on every paint.
nonisolated enum CotypingSuggestionFadeInPolicy {
    static let minimumDurationSeconds: Double = 0.05
    static let maximumDurationSeconds: Double = 0.30
    static let defaultDurationSeconds: Double = 0.15

    static func shouldFadeIn(
        isEnabled: Bool,
        overlayWasVisible: Bool,
        reduceMotionEnabled: Bool
    ) -> Bool {
        isEnabled && !overlayWasVisible && !reduceMotionEnabled
    }

    static func clampedDurationSeconds(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return defaultDurationSeconds }
        return min(maximumDurationSeconds, max(minimumDurationSeconds, seconds))
    }
}

nonisolated enum CotypingGhostFontSizing {
    static let minimumGhostFontSize: CGFloat = 14
    static let maximumGhostFontSize: CGFloat = 24
    static let maximumEstimatedGhostFontSize: CGFloat = 16
    static let fontToLineHeightRatio: CGFloat = 0.78
    static let absoluteMinimumPointSize: CGFloat = 9

    struct FieldFontMetrics: Equatable {
        let pointSize: CGFloat
        let ascender: CGFloat
        let descender: CGFloat
    }

    static func pointSize(
        caretHeight: CGFloat,
        fieldMetrics: FieldFontMetrics?,
        caretIsExact: Bool,
        sizeMultiplier: CGFloat = 1
    ) -> CGFloat {
        let maximum = caretIsExact ? maximumGhostFontSize : maximumEstimatedGhostFontSize
        let ratio = metricRatio(fieldMetrics) ?? fontToLineHeightRatio
        let autoSize = min(maximum, max(minimumGhostFontSize, caretHeight * ratio))
        return max(absoluteMinimumPointSize, autoSize * max(sizeMultiplier, 0))
    }

    static func renderStyle(
        from style: CotypingFieldStyle?,
        caretHeight: CGFloat,
        caretIsExact: Bool
    ) -> CotypingFieldStyle? {
        let referenceFont = style.flatMap(CotypingGhostStyle.font(from:))
        let metrics = referenceFont.map {
            FieldFontMetrics(
                pointSize: $0.pointSize,
                ascender: $0.ascender,
                descender: $0.descender)
        }
        let size = pointSize(
            caretHeight: caretHeight,
            fieldMetrics: metrics,
            caretIsExact: caretIsExact)
        return CotypingFieldStyle(
            fontName: style?.fontName,
            fontPointSize: size,
            colorHex: style?.colorHex,
            backgroundColorHex: style?.backgroundColorHex)
    }

    private static func metricRatio(_ metrics: FieldFontMetrics?) -> CGFloat? {
        guard let metrics, metrics.pointSize > 0 else { return nil }
        let glyphBoxHeight = metrics.ascender - metrics.descender
        guard glyphBoxHeight > 0 else { return nil }
        return metrics.pointSize / glyphBoxHeight
    }
}

nonisolated struct CotypingGhostFontSizeStabilizer {
    private var sessionKey: String?
    private var minCaretHeight: CGFloat?

    mutating func stabilizedCaretHeight(_ caretHeight: CGFloat, focusSessionKey: String) -> CGFloat {
        guard caretHeight > 0 else {
            return caretHeight
        }
        if sessionKey != focusSessionKey {
            sessionKey = focusSessionKey
            minCaretHeight = caretHeight
            return caretHeight
        }
        let stabilized = min(caretHeight, minCaretHeight ?? caretHeight)
        minCaretHeight = stabilized
        return stabilized
    }
}

nonisolated enum CotypingInsertedTextAdvance {
    static func width(of text: String, style: CotypingFieldStyle?) -> CGFloat? {
        guard !text.isEmpty,
              let style,
              let pointSize = style.fontPointSize,
              pointSize.isFinite,
              pointSize > 0 else {
            return nil
        }
        let font = style.fontName.flatMap { NSFont(name: $0, size: pointSize) }
            ?? NSFont.systemFont(ofSize: pointSize)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        guard width.isFinite, width > 0 else { return nil }
        return width
    }
}

/// The inline ghost text. Keep this visually close to host text instead of a
/// separate popup pill; CotypingRenderMode controls when popup placement is
/// necessary.
struct CotypingGhostView: View {
    let text: String
    var style: CotypingFieldStyle? = nil
    var showsChrome = false
    var acceptanceHintLabel: String? = nil
    var inlineLayout: CotypingInlineGhostLayout? = nil
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

    @ViewBuilder
    private var textView: some View {
        if !showsChrome, let inlineLayout {
            inlineTextView(layout: inlineLayout)
        } else {
            singleTextView
        }
    }

    private var singleTextView: some View {
        HStack(alignment: .firstTextBaseline, spacing: acceptanceHintLabel == nil ? 0 : 6) {
            Text(attributedText)
                .multilineTextAlignment(.leading)
                .lineLimit(showsChrome ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: true, vertical: true)

            if let acceptanceHintLabel {
                CotypingGhostKeycap(label: acceptanceHintLabel)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private func inlineTextView(layout: CotypingInlineGhostLayout) -> some View {
        let alignment: HorizontalAlignment = layout.isRightToLeft ? .trailing : .leading
        return VStack(alignment: alignment, spacing: 0) {
            ForEach(layout.lines) { line in
                let showsKeycap = line.showsKeycap && acceptanceHintLabel != nil
                HStack(alignment: .firstTextBaseline, spacing: showsKeycap ? CotypingAcceptanceHintLayout.spacing : 0) {
                    if layout.isRightToLeft, showsKeycap, let acceptanceHintLabel {
                        CotypingGhostKeycap(label: acceptanceHintLabel)
                    }

                    Text(line.text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: true)

                    if !layout.isRightToLeft, showsKeycap, let acceptanceHintLabel {
                        CotypingGhostKeycap(label: acceptanceHintLabel)
                    }
                }
                .padding(layout.isRightToLeft ? .trailing : .leading, line.leadingIndent)
                .fixedSize(horizontal: true, vertical: true)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var attributedText: AttributedString {
        guard showsChrome else {
            var attributed = AttributedString(text)
            attributed.foregroundColor = color
            attributed.font = font
            return attributed
        }
        return styledChromeText
    }

    private var styledChromeText: AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = color
        attributed.font = font
        let prefix = CotypingGhostHighlight.acceptancePrefix(in: text)
        guard !prefix.isEmpty, text.hasPrefix(prefix) else {
            return attributed
        }
        let characters = attributed.characters
        let end = characters.index(characters.startIndex, offsetBy: prefix.count)
        let range = characters.startIndex..<end
        attributed[range].foregroundColor = .primary
        attributed[range].font = .system(size: CotypingGhostStyle.clampedPointSize(style?.fontPointSize), weight: .semibold)
        return attributed
    }
}

private struct CotypingGhostKeycap: View {
    @Environment(\.colorScheme) private var colorScheme
    let label: String

    private var textColor: Color {
        colorScheme == .dark ? Color(white: 0.65) : Color(white: 0.45)
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color(white: 0.18) : Color(white: 0.95)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color(white: 0.30) : Color(white: 0.80)
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(textColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: true)
    }
}

nonisolated enum CotypingAcceptanceHintLayout {
    static let spacing: CGFloat = 6
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 4

    static func keycapSize(label: String?) -> CGSize {
        guard let label,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .zero
        }
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let textSize = (label as NSString).size(withAttributes: [.font: font])
        return CGSize(
            width: ceil(textSize.width + horizontalPadding),
            height: ceil(textSize.height + verticalPadding))
    }

    static func reservedSize(for textSize: CGSize, label: String?) -> CGSize {
        let keycap = keycapSize(label: label)
        guard keycap.width > 0 else {
            return textSize
        }
        return CGSize(
            width: textSize.width + spacing + keycap.width,
            height: max(textSize.height, keycap.height))
    }
}

nonisolated enum CotypingGhostHighlight {
    static func acceptancePrefix(in text: String) -> String {
        guard !text.isEmpty else { return "" }
        let chunk = CotypingCoordinator.nextWord(in: text)
        return text.hasPrefix(chunk) ? chunk : ""
    }
}

/// CoTabby-style inline layout: split long ghost text into visual rows before
/// SwiftUI renders it, so inline suggestions can wrap within the input bounds
/// instead of truncating at one screen-edge-clamped line.
nonisolated struct CotypingInlineGhostLayout: Equatable {
    struct Line: Equatable, Identifiable {
        let index: Int
        let text: String
        let leadingIndent: CGFloat
        let showsKeycap: Bool

        var id: Int { index }
    }

    let lines: [Line]
    let panelOriginX: CGFloat
    let lineHeight: CGFloat
    let topLineCenterOffsetFromCaret: CGFloat
    let isRightToLeft: Bool

    var minimumContentHeight: CGFloat {
        max(CGFloat(lines.count), 1) * max(lineHeight, 1)
    }

    private enum Metrics {
        static let caretGap: CGFloat = 6
        static let inputHorizontalPadding: CGFloat = 8
        static let fallbackScreenMargin: CGFloat = 16
        static let minimumLineWidth: CGFloat = 48
        static let lineHeightMultiplier: CGFloat = 1.25
    }

    static func make(
        text: String,
        caretRect: CGRect,
        inputFrameRect: CGRect?,
        style: CotypingFieldStyle?,
        visible: CGRect?,
        acceptanceHintLabel: String?,
        isRightToLeft: Bool
    ) -> CotypingInlineGhostLayout {
        let font = CotypingGhostStyle.resolvedFont(from: style)
        return make(
            text: text,
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            font: font,
            visible: visible,
            acceptanceHintLabel: acceptanceHintLabel,
            isRightToLeft: isRightToLeft)
    }

    static func make(
        text: String,
        caretRect: CGRect,
        inputFrameRect: CGRect?,
        font: NSFont,
        visible: CGRect?,
        acceptanceHintLabel: String?,
        isRightToLeft: Bool
    ) -> CotypingInlineGhostLayout {
        let normalizedText = normalizedDisplayText(text)
        let lineHeight = ceil(max(font.ascender - font.descender, font.pointSize * Metrics.lineHeightMultiplier))
        let keycapSize = CotypingAcceptanceHintLayout.keycapSize(label: acceptanceHintLabel)
        let showsAcceptanceHint = keycapSize.width > 0
        let keycapReservation = showsAcceptanceHint
            ? keycapSize.width + CotypingAcceptanceHintLayout.spacing
            : 0
        let visibleFrame = visible ?? fallbackVisibleFrame(around: caretRect)
        let usableFrame = usableTextFrame(
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            visibleFrame: visibleFrame,
            isRightToLeft: isRightToLeft)

        let firstLineAnchor: CGFloat
        let firstLineBudget: CGFloat
        if isRightToLeft {
            firstLineAnchor = min(
                max(caretRect.minX - Metrics.caretGap, usableFrame.minX),
                usableFrame.maxX)
            firstLineBudget = max(0, firstLineAnchor - usableFrame.minX - keycapReservation)
        } else {
            firstLineAnchor = min(
                max(caretRect.maxX + Metrics.caretGap, usableFrame.minX),
                usableFrame.maxX)
            firstLineBudget = max(0, usableFrame.maxX - firstLineAnchor - keycapReservation)
        }

        let overflowBudget = max(Metrics.minimumLineWidth, usableFrame.width - keycapReservation)
        let singleLineFits = !normalizedText.contains("\n")
            && measuredWidth(normalizedText, font: font) <= firstLineBudget

        if singleLineFits {
            return CotypingInlineGhostLayout(
                lines: [
                    Line(index: 0, text: normalizedText, leadingIndent: 0, showsKeycap: showsAcceptanceHint)
                ],
                panelOriginX: firstLineAnchor,
                lineHeight: lineHeight,
                topLineCenterOffsetFromCaret: 0,
                isRightToLeft: isRightToLeft)
        }

        let panelOriginX = isRightToLeft ? usableFrame.maxX : usableFrame.minX
        var remainingText = normalizedText
        var rawLines: [(text: String, leadingIndent: CGFloat)] = []
        var startsBelowCaret = false

        if firstLineBudget >= Metrics.minimumLineWidth {
            let split = splitPrefix(from: remainingText, maxWidth: firstLineBudget, font: font)
            if !split.line.isEmpty {
                let indent = isRightToLeft
                    ? panelOriginX - firstLineAnchor
                    : firstLineAnchor - panelOriginX
                rawLines.append((split.line, indent))
                remainingText = split.remainder
            } else {
                startsBelowCaret = true
            }
        } else {
            startsBelowCaret = true
        }

        while !remainingText.isEmpty {
            let split = splitPrefix(from: remainingText, maxWidth: overflowBudget, font: font)
            guard !split.line.isEmpty else { break }
            rawLines.append((split.line, 0))
            remainingText = split.remainder
        }

        if rawLines.isEmpty {
            rawLines.append((normalizedText, 0))
            startsBelowCaret = true
        }

        let finalLines = rawLines.enumerated().map { offset, rawLine in
            Line(
                index: offset,
                text: rawLine.text,
                leadingIndent: rawLine.leadingIndent,
                showsKeycap: showsAcceptanceHint && offset == rawLines.count - 1)
        }

        return CotypingInlineGhostLayout(
            lines: finalLines,
            panelOriginX: panelOriginX,
            lineHeight: lineHeight,
            topLineCenterOffsetFromCaret: startsBelowCaret ? -lineHeight : 0,
            isRightToLeft: isRightToLeft)
    }

    func panelFrame(for contentSize: CGSize, caretRect: CGRect, visible: CGRect?) -> CGRect {
        let topLineCenterY = caretRect.midY + topLineCenterOffsetFromCaret
        let width = max(contentSize.width, Metrics.minimumLineWidth)
        let height = max(contentSize.height, lineHeight)
        var frame = CGRect(
            x: isRightToLeft ? panelOriginX - width : panelOriginX,
            y: topLineCenterY - height + (lineHeight / 2),
            width: width,
            height: height)
        guard let visible else { return frame }
        if frame.minX < visible.minX + Metrics.caretGap {
            frame.origin.x = visible.minX + Metrics.caretGap
        } else if frame.maxX > visible.maxX - Metrics.caretGap {
            frame.origin.x = visible.maxX - frame.width - Metrics.caretGap
        }
        if frame.minY < visible.minY + Metrics.caretGap {
            frame.origin.y = visible.minY + Metrics.caretGap
        } else if frame.maxY > visible.maxY - Metrics.caretGap {
            frame.origin.y = visible.maxY - frame.height - Metrics.caretGap
        }
        return frame
    }

    static func renderedWidth(of text: String, font: NSFont) -> CGFloat {
        measuredWidth(normalizedDisplayText(text), font: font)
    }

    static func estimatedContentSize(
        for layout: CotypingInlineGhostLayout,
        style: CotypingFieldStyle?,
        acceptanceHintLabel: String?
    ) -> CGSize {
        let font = CotypingGhostStyle.resolvedFont(from: style)
        let keycap = CotypingAcceptanceHintLayout.keycapSize(label: acceptanceHintLabel)
        let widest = layout.lines.map { line -> CGFloat in
            let keycapWidth = line.showsKeycap && keycap.width > 0
                ? CotypingAcceptanceHintLayout.spacing + keycap.width
                : 0
            return line.leadingIndent + measuredWidth(line.text, font: font) + keycapWidth
        }.max() ?? Metrics.minimumLineWidth
        return CGSize(
            width: ceil(max(widest, Metrics.minimumLineWidth)),
            height: ceil(layout.minimumContentHeight))
    }

    private static func usableTextFrame(
        caretRect: CGRect,
        inputFrameRect: CGRect?,
        visibleFrame: CGRect,
        isRightToLeft: Bool
    ) -> CGRect {
        if let inputFrame = inputFrameRect?.standardized,
           inputFrame.width > Metrics.minimumLineWidth {
            let minX = max(
                inputFrame.minX + Metrics.inputHorizontalPadding,
                visibleFrame.minX + Metrics.fallbackScreenMargin)
            let maxX = min(
                inputFrame.maxX - Metrics.inputHorizontalPadding,
                visibleFrame.maxX - Metrics.fallbackScreenMargin)
            if maxX - minX > Metrics.minimumLineWidth {
                return CGRect(x: minX, y: inputFrame.minY, width: maxX - minX, height: inputFrame.height)
            }
        }

        let fallbackMinX: CGFloat
        let fallbackMaxX: CGFloat
        if isRightToLeft {
            fallbackMinX = visibleFrame.minX + Metrics.fallbackScreenMargin
            fallbackMaxX = caretRect.minX - Metrics.caretGap
        } else {
            fallbackMinX = caretRect.maxX + Metrics.caretGap
            fallbackMaxX = visibleFrame.maxX - Metrics.fallbackScreenMargin
        }
        return CGRect(
            x: fallbackMinX,
            y: caretRect.minY,
            width: max(Metrics.minimumLineWidth, fallbackMaxX - fallbackMinX),
            height: caretRect.height)
    }

    private static func fallbackVisibleFrame(around caretRect: CGRect) -> CGRect {
        CGRect(
            x: caretRect.minX - 16,
            y: caretRect.minY - 300,
            width: 800,
            height: 600)
    }

    private static func normalizedDisplayText(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let normalizedLines = lines.map { line -> String in
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { return "" }
            let joined = words.joined(separator: " ")
            return line.first?.isWhitespace == true ? " \(joined)" : joined
        }
        return normalizedLines.joined(separator: "\n")
    }

    private static func splitPrefix(
        from text: String,
        maxWidth: CGFloat,
        font: NSFont
    ) -> (line: String, remainder: String) {
        let source = text.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return ("", "") }
        let safeMaxWidth = max(maxWidth, Metrics.minimumLineWidth)

        if let newlineIndex = source.firstIndex(of: "\n") {
            return splitAtNewline(
                source: source,
                newlineIndex: newlineIndex,
                maxWidth: safeMaxWidth,
                font: font)
        }

        if measuredWidth(source, font: font) <= safeMaxWidth {
            return (source, "")
        }

        let characters = Array(source)
        var lastWhitespaceBreak: Int?
        for endIndex in characters.indices {
            let prefix = String(characters[...endIndex])
            if characters[endIndex].isWhitespace {
                lastWhitespaceBreak = endIndex + 1
            }

            if measuredWidth(prefix, font: font) > safeMaxWidth {
                if let breakIndex = lastWhitespaceBreak, breakIndex > 0 {
                    return (
                        String(characters[..<breakIndex]).trimmingCharacters(in: .whitespaces),
                        String(characters[breakIndex...]).trimmingCharacters(in: .whitespaces))
                }
                let splitIndex = max(endIndex, 1)
                return (
                    String(characters[..<splitIndex]).trimmingCharacters(in: .whitespaces),
                    String(characters[splitIndex...]).trimmingCharacters(in: .whitespaces))
            }
        }

        return (source, "")
    }

    private static func splitAtNewline(
        source: String,
        newlineIndex: String.Index,
        maxWidth: CGFloat,
        font: NSFont
    ) -> (line: String, remainder: String) {
        let segment = String(source[..<newlineIndex]).trimmingCharacters(in: .whitespaces)
        let afterIndex = source.index(after: newlineIndex)
        let afterNewline = afterIndex < source.endIndex
            ? String(source[afterIndex...]).trimmingCharacters(in: .whitespaces)
            : ""
        guard !segment.isEmpty else {
            return splitPrefix(from: afterNewline, maxWidth: maxWidth, font: font)
        }
        if measuredWidth(segment, font: font) <= maxWidth {
            return (segment, afterNewline)
        }
        let widthSplit = splitPrefix(from: segment, maxWidth: maxWidth, font: font)
        let combined: String
        if widthSplit.remainder.isEmpty {
            combined = afterNewline
        } else if afterNewline.isEmpty {
            combined = widthSplit.remainder
        } else {
            combined = widthSplit.remainder + "\n" + afterNewline
        }
        return (widthSplit.line, combined)
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}

/// Pre-wraps popup/mirror ghost text so multi-line suggestions do not collapse
/// into a single truncated row. Inline uses `CotypingInlineGhostLayout`; popup
/// has its own chrome and independently bounded rows.
nonisolated enum CotypingGhostTextLayout {
    static let maxMirrorTextWidth: CGFloat = 420
    static let minMirrorTextWidth: CGFloat = 80
    static let maxMirrorLines = 4
    private static let screenMargin: CGFloat = 24

    struct Layout: Equatable {
        let lines: [String]
        let textSize: CGSize

        var displayText: String { lines.joined(separator: "\n") }
    }

    static func mirrorLayout(
        text: String,
        style: CotypingFieldStyle?,
        visible: CGRect?,
        maxLines: Int = maxMirrorLines
    ) -> Layout {
        let font = CotypingGhostStyle.resolvedFont(from: style)
        let maxWidth = mirrorTextWidthBudget(visible: visible)
        let lines = wrappedLines(
            text: text,
            font: font,
            maxWidth: maxWidth,
            maxLines: maxLines)
        let lineHeight = ceil(font.ascender - font.descender)
        let widestLine = lines
            .map { measuredWidth($0, font: font) }
            .max() ?? minMirrorTextWidth
        let textSize = CGSize(
            width: ceil(min(maxWidth, max(widestLine, minMirrorTextWidth))),
            height: ceil(max(CGFloat(lines.count), 1) * max(lineHeight, 1)))
        return Layout(lines: lines, textSize: textSize)
    }

    static func wrappedLines(
        text: String,
        font: NSFont,
        maxWidth: CGFloat,
        maxLines: Int = maxMirrorLines
    ) -> [String] {
        let normalized = normalizedDisplayText(text)
        guard maxLines > 0 else { return [] }
        guard !normalized.isEmpty else { return [] }

        let paragraphs = normalized.components(separatedBy: .newlines)
        var result: [String] = []
        var truncated = false
        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            var remaining = paragraph.trimmingCharacters(in: .whitespaces)
            if remaining.isEmpty {
                continue
            }
            while !remaining.isEmpty {
                guard result.count < maxLines else {
                    truncated = true
                    break
                }
                let split = splitPrefix(remaining, font: font, maxWidth: maxWidth)
                result.append(split.line)
                remaining = split.remainder
            }
            if truncated {
                break
            }
            if result.count >= maxLines,
               paragraphs.dropFirst(paragraphIndex + 1).contains(where: {
                   !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
               }) {
                truncated = true
                break
            }
        }

        if result.isEmpty {
            return []
        }
        if truncated {
            result[result.count - 1] = ellipsized(result[result.count - 1], font: font, maxWidth: maxWidth)
        }
        return result
    }

    private static func mirrorTextWidthBudget(visible: CGRect?) -> CGFloat {
        guard let visible else { return maxMirrorTextWidth }
        let screenBudget = visible.width - (screenMargin * 2)
        return min(maxMirrorTextWidth, max(minMirrorTextWidth, screenBudget))
    }

    private static func normalizedDisplayText(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { line in
            line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        return lines
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitPrefix(
        _ text: String,
        font: NSFont,
        maxWidth: CGFloat
    ) -> (line: String, remainder: String) {
        let source = text.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return ("", "") }
        guard measuredWidth(source, font: font) > maxWidth else {
            return (source, "")
        }

        let words = source.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return ("", "") }
        var line = ""
        var usedWords = 0

        for word in words {
            let candidate = line.isEmpty ? word : "\(line) \(word)"
            if measuredWidth(candidate, font: font) <= maxWidth || line.isEmpty {
                line = candidate
                usedWords += 1
            } else {
                break
            }
        }

        if measuredWidth(line, font: font) > maxWidth {
            return splitLongWord(line, font: font, maxWidth: maxWidth)
        }

        let remainder = words.dropFirst(usedWords).joined(separator: " ")
        return (line, remainder)
    }

    private static func splitLongWord(
        _ word: String,
        font: NSFont,
        maxWidth: CGFloat
    ) -> (line: String, remainder: String) {
        var prefix = ""
        var consumed = 0
        for character in word {
            let candidate = prefix + String(character)
            if !prefix.isEmpty, measuredWidth(candidate, font: font) > maxWidth {
                break
            }
            prefix = candidate
            consumed += 1
        }
        guard consumed > 0 else { return (String(word.prefix(1)), String(word.dropFirst())) }
        return (prefix, String(word.dropFirst(consumed)))
    }

    private static func ellipsized(_ line: String, font: NSFont, maxWidth: CGFloat) -> String {
        let suffix = "..."
        var candidate = line.trimmingCharacters(in: .whitespaces)
        while !candidate.isEmpty,
              measuredWidth(candidate + suffix, font: font) > maxWidth {
            candidate.removeLast()
        }
        return candidate.isEmpty ? suffix : candidate + suffix
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}

/// Detects the strong writing direction near the caret. We walk backwards
/// because the characters closest to the caret are the best signal for ghost
/// placement and post-accept drift direction.
nonisolated enum CotypingTextDirectionDetector {
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars.reversed() {
            if isStrongRTL(scalar) { return true }
            if isStrongLTR(scalar) { return false }
        }
        return false
    }

    private static func isStrongRTL(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value >= 0x0590 && value <= 0x08FF { return true }
        if value >= 0xFB1D && value <= 0xFDFF { return true }
        if value >= 0xFE70 && value <= 0xFEFF { return true }
        if value == 0x200F || value == 0x061C { return true }
        return false
    }

    private static func isStrongLTR(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value >= 0x0041 && value <= 0x005A { return true }
        if value >= 0x0061 && value <= 0x007A { return true }
        if value >= 0x00C0 && value <= 0x024F { return true }
        if value >= 0x0370 && value <= 0x03FF { return true }
        if value >= 0x0400 && value <= 0x04FF { return true }
        if value >= 0x4E00 && value <= 0x9FFF { return true }
        if value == 0x200E { return true }
        return false
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
