import SwiftUI

// MARK: - Hero panel

/// Slate "plate" card echoing the app icon: dark in both appearances, with
/// a faint bright-teal hairline. Content on it must use fixed light
/// foregrounds (white / Brand.tealBright), never semantic label colors —
/// the plate does not flip with the system appearance.
struct HeroPanel<Content: View>: View {
    var radius: CGFloat = Brand.Radius.card
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        content
            .padding(14)
            .background(Brand.plateGradient,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(contrast == .increased
                                  ? Color.white.opacity(0.5)
                                  : Brand.tealBright.opacity(0.14)))
    }
}

// MARK: - HUD capsule

extension View {
    /// The one floating-surface chrome: material fill, hairline border, HUD
    /// radius, soft shadow. Shared by the dictation HUD, the audio-source
    /// banner, and the recording pill so every floating capsule reads as one
    /// family. Pass `shadowed: false` inside borderless NSPanels sized
    /// exactly to their content — a SwiftUI shadow would clip at the panel
    /// edge there.
    func hudCapsule(radius: CGFloat = Brand.Radius.hud, shadowed: Bool = true) -> some View {
        background(.regularMaterial,
                   in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(shadowed ? 0.12 : 0), radius: shadowed ? 6 : 0, y: shadowed ? 3 : 0)
    }
}
