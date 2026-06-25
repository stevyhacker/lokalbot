import Foundation

/// How the ghost overlay presents a suggestion. Ported from Cotabby's
/// `CompletionRenderMode`. Inline draws next to the caret; mirror draws the
/// suggestion as a popup below the caret, used when caret geometry is
/// unreliable or the caret sits mid-line (inline would paint over the trailing
/// characters the host still shows).
nonisolated enum CotypingRenderMode: Equatable, Sendable {
    case inline
    case mirror(reason: MirrorReason)

    nonisolated enum MirrorReason: String, Equatable, Sendable {
        /// Caret rect was estimated from the field frame, so inline ghost text
        /// would drift as the user types.
        case caretGeometryEstimated
        /// Real characters follow the caret before the next line break; inline
        /// ghost text would draw on top of them.
        case caretMidLine
        /// The user pinned the preference to always use the popup.
        case userPreference
    }

    var isMirror: Bool { if case .mirror = self { true } else { false } }
}

/// User-facing render preference. Ported from Cotabby's `MirrorPreference`.
/// `auto` defers to caret-geometry quality; the two pins let a user override
/// when the auto rule misfires for their host mix.
enum CotypingMirrorPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case alwaysInline
    case alwaysMirror

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Automatic"
        case .alwaysInline: "Always inline"
        case .alwaysMirror: "Always popup"
        }
    }
}

/// Pure rule that translates caret-geometry quality + the mid-line signal + the
/// user preference into a `CotypingRenderMode`. Ported from Cotabby's
/// `CompletionRenderModePolicy`. Pulling the decision into a value type keeps the
/// overlay focused on AppKit layout and makes the rule unit-testable; adding a
/// trigger means editing this one struct, not threading conditionals through the
/// controller.
nonisolated struct CotypingRenderModePolicy: Equatable, Sendable {
    var userPreference: CotypingMirrorPreference

    init(userPreference: CotypingMirrorPreference = .auto) {
        self.userPreference = userPreference
    }

    /// Whether the caret is at the end of its line: when there is no text after
    /// it, or that text begins with a newline. Pure derivation from the field's
    /// trailing text — shared by the policy and the coordinator so they agree.
    static func isCaretAtEndOfLine(trailingText: String) -> Bool {
        guard let first = trailingText.first else { return true }
        return first.isNewline
    }

    func mode(caretIsExact: Bool, isCaretAtEndOfLine: Bool) -> CotypingRenderMode {
        // A mid-line caret has no inline home: ghost text would paint over the
        // trailing characters. This overrides an explicit `.alwaysInline` pin
        // too, because inline cannot render mid-line at all.
        if !isCaretAtEndOfLine {
            return .mirror(reason: .caretMidLine)
        }
        return preferenceMode(caretIsExact: caretIsExact)
    }

    private func preferenceMode(caretIsExact: Bool) -> CotypingRenderMode {
        switch userPreference {
        case .alwaysInline:
            return .inline
        case .alwaysMirror:
            return .mirror(reason: .userPreference)
        case .auto:
            // Exact (boundsForRange / text-marker) geometry lands close enough to
            // the real caret to render inline; an estimated caret can drift as
            // the user types, so route it to the popup.
            return caretIsExact ? .inline : .mirror(reason: .caretGeometryEstimated)
        }
    }
}

/// Bundles the signals the overlay needs to pick a render mode, carried alongside
/// the caret rect / style so `show()` can render without re-reading the field.
struct CotypingOverlayPlacement: Equatable, Sendable {
    let caretIsExact: Bool
    let isCaretAtEndOfLine: Bool
    let preference: CotypingMirrorPreference

    var mode: CotypingRenderMode {
        CotypingRenderModePolicy(userPreference: preference)
            .mode(caretIsExact: caretIsExact, isCaretAtEndOfLine: isCaretAtEndOfLine)
    }

    /// Inline-safe default so call sites that don't supply a placement render
    /// exactly as before (inline, end of line, exact caret).
    static let inlineDefault = CotypingOverlayPlacement(caretIsExact: true, isCaretAtEndOfLine: true, preference: .auto)
}
