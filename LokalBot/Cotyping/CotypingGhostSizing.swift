import AppKit

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
