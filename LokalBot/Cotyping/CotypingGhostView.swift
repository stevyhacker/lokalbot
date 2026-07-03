import AppKit
import SwiftUI

/// The inline ghost text. Keep this visually close to host text instead of a
/// separate popup pill; CotypingRenderMode controls when popup placement is
/// necessary.
struct CotypingGhostView: View {
    let text: String
    var style: CotypingFieldStyle?
    var showsChrome = false
    var acceptanceHintLabel: String?
    var inlineLayout: CotypingInlineGhostLayout?
    /// Average luminance (0…1) of the host pixels behind the ghost, sampled from
    /// the screen when available; lets the color contrast with the real
    /// background instead of guessing from AX/appearance.
    var backgroundLuminance: CGFloat?

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
        let chunk = CotypingAcceptanceChunker.nextWord(in: text)
        return text.hasPrefix(chunk) ? chunk : ""
    }
}
