import SwiftUI

// MARK: - Semantic brand roles

extension Brand {
    /// Live-capture indicator (recording, dictating): the icon's amber antenna
    /// dot, and the same convention as macOS's amber mic-in-use dot. Buttons
    /// that *stop* a capture stay `.red` — amber marks state, red marks the
    /// destructive action.
    static let recording = amber

    /// Shared corner radii. Chips are capsules; everything rectangular snaps
    /// to one of these instead of a per-view magic number.
    enum Radius {
        /// Inline wells and small controls (text areas, thumbnails).
        static let control: CGFloat = 8
        /// Panels, cards, toasts, and chat bubbles.
        static let panel: CGFloat = 12
        /// Hero surfaces (getting-started card, onboarding cards).
        static let card: CGFloat = 14
        /// Floating capsules (dictation HUD, banners, the recording pill).
        static let hud: CGFloat = 20
    }
}

// MARK: - Workspace shell

/// Warm, low-contrast workspace colors inspired by focused writing tools.
/// Every role has a dark equivalent so LokalBot still follows the Mac's
/// appearance instead of forcing a fixed light theme.
enum WorkspacePalette {
    static func canvas(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.075, green: 0.078, blue: 0.071)
            : Color(red: 0.953, green: 0.945, blue: 0.929)
    }

    static func surface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.105, green: 0.109, blue: 0.101)
            : Color(red: 0.995, green: 0.992, blue: 0.982)
    }

    static func control(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.145, green: 0.149, blue: 0.137)
            : Color(red: 0.941, green: 0.932, blue: 0.915)
    }

    static func border(
        for colorScheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> Color {
        if colorScheme == .dark {
            return Color.white.opacity(contrast == .increased ? 0.18 : 0.09)
        }
        return Color.black.opacity(contrast == .increased ? 0.18 : 0.08)
    }

    static func shadow(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.black.opacity(0.32)
            : Color(red: 0.24, green: 0.21, blue: 0.16).opacity(0.12)
    }
}

private struct WorkspaceSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        content
            .background(WorkspacePalette.surface(for: colorScheme))
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    WorkspacePalette.border(for: colorScheme, contrast: contrast),
                    lineWidth: 1)
            }
            .shadow(
                color: WorkspacePalette.shadow(for: colorScheme),
                radius: colorScheme == .dark ? 14 : 18,
                y: 6)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(WorkspacePalette.canvas(for: colorScheme))
    }
}

private struct WorkspaceControlModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)

        content
            .background(WorkspacePalette.control(for: colorScheme), in: shape)
            .overlay {
                shape.strokeBorder(
                    WorkspacePalette.border(for: colorScheme, contrast: contrast),
                    lineWidth: 1)
            }
    }
}

extension View {
    /// Insets a detail pane into the soft canvas used by the main workspace.
    func workspaceSurface() -> some View {
        modifier(WorkspaceSurfaceModifier())
    }

    /// Quiet control chrome for search and other shell-level fields.
    func workspaceControl() -> some View {
        modifier(WorkspaceControlModifier())
    }
}

// MARK: - Chips

enum ChipSize {
    case regular, compact

    var font: Font { self == .regular ? .caption : .caption2 }
    var horizontalPadding: CGFloat { self == .regular ? 9 : 7 }
    var verticalPadding: CGFloat { self == .regular ? 4 : 2 }
}

extension View {
    /// The one capsule-chip chrome (padding + quiet fill) shared by metadata
    /// badges, stat pills, kind chips, and activity labels. Apply to composite
    /// content; use `BrandChip` for the plain icon+text case.
    func chipChrome(_ size: ChipSize = .regular) -> some View {
        padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

/// A small capsule chip: optional SF Symbol + text, secondary foreground.
struct BrandChip: View {
    var icon: String?
    let text: String
    var size: ChipSize = .regular

    var body: some View {
        Group {
            if let icon {
                Label(text, systemImage: icon).labelStyle(.titleAndIcon)
            } else {
                Text(text)
            }
        }
        .font(size.font.monospacedDigit())
        .foregroundStyle(.secondary)
        .chipChrome(size)
    }
}

// MARK: - Status dot

/// A small state-colored dot; `pulses` adds the expanding ring used by live
/// recording indicators.
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8
    var pulses: Bool = false
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                if pulses {
                    Circle()
                        .stroke(color.opacity(0.55), lineWidth: 3)
                        .scaleEffect(pulse ? 2.4 : 1)
                        .opacity(pulse ? 0 : 0.7)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false),
                                   value: pulse)
                }
            }
            .onAppear { pulse = pulses }
            .onChange(of: pulses) { _, now in pulse = now }
    }
}

// MARK: - Error toast

/// The one transient-error presentation: a dismissible material capsule pinned
/// to a window edge via `.overlay(alignment: .bottom)`. Persistent per-item
/// failures stay inline next to their rows; conversational errors stay in
/// their bubbles.
struct ErrorToast: View {
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).lineLimit(2)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button(action: dismiss) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.panel).strokeBorder(.orange.opacity(0.4)))
        .padding(12)
    }
}

// MARK: - Icon tile

/// The gradient icon tile from onboarding, promoted app-wide so feature
/// headers and hero cards share one visual anchor.
struct IconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.84), tint],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: tint.opacity(0.32), radius: size * 0.14, y: size * 0.06)

            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Section header

/// Uppercase caption header for list groupings (meeting-list day labels,
/// menu-bar Recent, inspector headings) — one treatment everywhere.
struct SectionHeader: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Stat tile

/// Icon + value + label stat chip (timeline header stats, Type stats,
/// Settings metrics). The value keeps monospaced digits so rows align.
struct StatTile: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
        .chipChrome()
    }
}
