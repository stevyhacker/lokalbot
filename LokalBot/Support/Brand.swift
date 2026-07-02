import SwiftUI

/// Brand identity, kept in lockstep with the app icon and the marketing site.
/// The icon is an L-shaped robot on a dark slate plate, drawn in a mint→teal
/// gradient (`#6ef2dc → #23c4ae`) with a single amber antenna (`#fbbf24`).
/// These are the only three brand colors — applied as the app accent so the UI
/// reads as LokalBot, not "default macOS accent", reinforcing the mascot and
/// the privacy/local-first stance.
enum Brand {
    /// Primary accent (the gradient's mid-point). Used for `.tint`.
    static let teal = Color(red: 0.137, green: 0.769, blue: 0.682)       // #23c4ae
    /// Bright end of the gradient — glows, active states, the recording eye.
    static let tealBright = Color(red: 0.431, green: 0.949, blue: 0.863) // #6ef2dc
    /// The single warm note — reserved for the live "recording" indicator,
    /// mirroring the antenna dot on the icon.
    static let amber = Color(red: 0.984, green: 0.749, blue: 0.141)      // #fbbf24
    /// "Me" speaker (mic track) — the user's own voice.
    static let me = teal
    /// "Them" speaker (system track) — other participants.
    static let them = Color(red: 0.49, green: 0.62, blue: 0.76)

    /// The icon's dark plate, brought into the app for hero surfaces and
    /// HUDs. Deliberately stays dark in both appearances — hero surfaces
    /// read as "plated" like the icon, so content on slate must use fixed
    /// light foregrounds (white / tealBright), never semantic label colors.
    static let slate = Color(red: 0.059, green: 0.090, blue: 0.165)          // #0f172a
    static let slateElevated = Color(red: 0.118, green: 0.161, blue: 0.231)  // #1e293b

    /// Plate gradient for hero panels — elevated slate falling to slate,
    /// echoing the icon's plate lighting.
    static let plateGradient = LinearGradient(
        colors: [slateElevated, slate],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Vertical gradient used on hero surfaces (onboarding, empty states) to
    /// echo the icon body without leaning on the system accent.
    static let gradient = LinearGradient(
        colors: [tealBright, teal],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// A view modifier that sets the brand tint and offers a softer fallback
    /// in High Contrast / Increase Contrast where the teal can read thin.
    struct TintModifier: ViewModifier {
        func body(content: Content) -> some View {
            content.tint(teal)
                .accentColor(teal)
        }
    }
}

extension View {
    /// Apply the LokalBot brand accent app-wide.
    func brandTinted() -> some View { modifier(Brand.TintModifier()) }
}
