import AppKit

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
