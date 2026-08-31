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

// MARK: - Workspace panels

/// Shared section chrome for evidence-oriented pages such as Today, meeting
/// outcomes, model setup, and autocomplete onboarding.
struct WorkspaceSection<Content: View>: View {
    let title: String
    let icon: String
    var searchQuery = ""
    var activeMatchIndex: Int?
    var searchLocation: MeetingPageSearchMatch.Location?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                if let searchLocation {
                    SearchHighlightedText(
                        title,
                        query: searchQuery,
                        activeMatchIndex: activeMatchIndex
                    )
                    .id(searchLocation)
                } else {
                    Text(title)
                }
            } icon: {
                Image(systemName: icon)
            }
            .font(WorkspaceTypography.sectionTitle)
            content
        }
        .workspacePanel()
    }
}

struct EmptyWorkspaceRow: View {
    let text: String
    var searchQuery = ""
    var activeMatchIndex: Int?

    var body: some View {
        SearchHighlightedText(
            text,
            query: searchQuery,
            activeMatchIndex: activeMatchIndex
        )
        .font(WorkspaceTypography.body)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }
}

/// Compact transcript citation control shared by meeting and outcome views.
struct EvidencePill: View {
    let citation: OutcomeSourceCitation
    var searchQuery = ""
    var activeMatchIndex: Int?
    var searchLocation: MeetingPageSearchMatch.Location?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                if let searchLocation {
                    SearchHighlightedText(
                        Transcript.stamp(citation.start),
                        query: searchQuery,
                        activeMatchIndex: activeMatchIndex
                    )
                    .id(searchLocation)
                } else {
                    Text(Transcript.stamp(citation.start))
                }
            } icon: {
                Image(systemName: "quote.bubble")
            }
            .font(WorkspaceTypography.metadata.monospacedDigit())
        }
        .buttonStyle(.borderless)
        .help(citation.excerpt)
        .accessibilityLabel("Jump to evidence at \(Transcript.stamp(citation.start))")
    }
}
