import AppKit
import Foundation

/// The focused field's own font/color, resolved once per field session from AX
/// and carried as plain value types (no `NSFont`/`NSColor`) so the snapshot
/// stays `Equatable`/`Sendable` and cheap across async boundaries. Ported from
/// Cotabby's `ResolvedFieldStyle`. Empty / nil falls back to the overlay defaults.
nonisolated struct CotypingFieldStyle: Equatable, Sendable {
    /// PostScript font name suitable for `NSFont(name:size:)`.
    let fontName: String?
    /// Host-reported point size; used (clamped) so the ghost matches the field's scale.
    let fontPointSize: CGFloat?
    /// Foreground text color as a 6-digit hex string.
    let colorHex: String?

    var isEmpty: Bool { fontName == nil && colorHex == nil }

    init(fontName: String? = nil, fontPointSize: CGFloat? = nil, colorHex: String? = nil) {
        self.fontName = fontName
        self.fontPointSize = fontPointSize
        self.colorHex = colorHex
    }
}

/// Hex-string ↔ `NSColor` conversion for ghost-text colors. Ported from
/// Cotabby's `SuggestionTextColorCodec`: persistence (hex) and rendering
/// (`NSColor`) share one round-trip-correct path.
enum CotypingTextColorCodec {
    static func nsColor(fromHex hex: String?) -> NSColor? {
        guard let hex else { return nil }
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
        guard normalized.count == 6,
              normalized.unicodeScalars.allSatisfy({ valid.contains($0) }) else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: normalized).scanHexInt64(&value) else { return nil }
        let red = CGFloat((value & 0xFF0000) >> 16) / 255
        let green = CGFloat((value & 0x00FF00) >> 8) / 255
        let blue = CGFloat(value & 0x0000FF) / 255
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    static func hexString(from nsColor: NSColor) -> String? {
        guard let srgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        let red = Int((srgb.redComponent * 255).rounded())
        let green = Int((srgb.greenComponent * 255).rounded())
        let blue = Int((srgb.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}

/// Derives the ghost text's font/color from the host field's resolved style, so
/// the suggestion reads as a continuation of what the user is typing instead of
/// always using the system font + a fixed gray. Ported in spirit from Cotabby's
/// overlay styling. Pure given AppKit; all fallbacks are explicit and testable.
enum CotypingGhostStyle {
    static let minPointSize: CGFloat = 9
    static let maxPointSize: CGFloat = 28
    static let defaultPointSize: CGFloat = 13
    /// Ghost opacity relative to the host text color — reads as a suggestion, not typed text.
    static let ghostOpacity: CGFloat = 0.45

    /// Clamps a host-reported point size to a sane range so a giant field font
    /// can't blow up the ghost and a tiny one can't vanish; default when nil.
    static func clampedPointSize(_ size: CGFloat?) -> CGFloat {
        guard let size else { return defaultPointSize }
        return min(maxPointSize, max(minPointSize, size))
    }

    /// Ghost font matching the host family at the clamped size, or nil (caller
    /// falls back to the system font at the clamped / default size).
    static func font(from style: CotypingFieldStyle?) -> NSFont? {
        guard let style, let name = style.fontName else { return nil }
        return NSFont(name: name, size: clampedPointSize(style.fontPointSize))
    }

    /// Concrete AppKit font used for measuring and rendering fallback sizing.
    /// `NSHostingView.fittingSize` can briefly report a near-zero width after a
    /// SwiftUI root view swap; measuring the text directly keeps the panel wide
    /// enough even when the completion begins with a leading space.
    static func resolvedFont(from style: CotypingFieldStyle?) -> NSFont {
        font(from: style) ?? .systemFont(ofSize: clampedPointSize(style?.fontPointSize))
    }

    static func measuredTextSize(_ text: String, style: CotypingFieldStyle?) -> CGSize {
        guard !text.isEmpty else { return .zero }
        let size = (text as NSString).size(withAttributes: [.font: resolvedFont(from: style)])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// Dimmed host text color so the suggestion reads as a hint, or nil (caller
    /// falls back to the secondary label color).
    static func ghostColor(from style: CotypingFieldStyle?) -> NSColor? {
        guard let style, let hex = style.colorHex,
              let host = CotypingTextColorCodec.nsColor(fromHex: hex) else { return nil }
        return host.withAlphaComponent(ghostOpacity)
    }
}
