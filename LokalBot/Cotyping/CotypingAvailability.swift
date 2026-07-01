import Foundation

/// Pure per-field gating: given the settings and the current focus, should
/// cotyping offer a suggestion here? Mirrors the relevant subset of Cotabby's
/// `SuggestionAvailabilityEvaluator`. Permission gating (Accessibility / Input
/// Monitoring) is handled at subsystem start by `CotypingCoordinator`; this
/// decides only the per-keystroke "is this field eligible" question.
enum CotypingAvailability {
    /// Returns a human-readable reason to suppress, or `nil` when a suggestion
    /// may be generated for `focus`.
    static func disabledReason(
        enabled: Bool,
        excludedApps: [String],
        excludedDomains: [String] = [],
        suggestInIntegratedTerminals: Bool = false,
        selfBundleID: String?,
        focus: CotypingFocus
    ) -> String? {
        guard enabled else { return "Cotyping is off." }

        // Never suggest inside LokalBot itself (avoids feedback into our own UI).
        if let selfBundleID, focus.bundleID == selfBundleID {
            return "Off in LokalBot."
        }

        if isExcluded(appName: focus.appName, bundleID: focus.bundleID, excluded: excludedApps) {
            return "Disabled in \(focus.appName.isEmpty ? "this app" : focus.appName)."
        }

        if CotypingBrowserDomain.isHostDisabled(focus.host, excludedDomains: excludedDomains) {
            return "Disabled on \(focus.host ?? "this site")."
        }

        if CotypingSurfaceClassifier.classify(bundleID: focus.bundleID) == .terminal {
            return "Not available in terminal apps."
        }

        if !suggestInIntegratedTerminals, focus.field?.isIntegratedTerminal == true {
            return "Not available in the integrated terminal."
        }

        switch focus.capability {
        case .supported:
            return nil
        case .blocked(let why), .unsupported(let why):
            return why
        }
    }

    /// Case-insensitive substring match against the user's exclusion list,
    /// checked against both the app display name and bundle identifier.
    static func isExcluded(appName: String, bundleID: String?, excluded: [String]) -> Bool {
        let needles = excluded
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !needles.isEmpty else { return false }
        let haystacks = [appName.lowercased(), (bundleID ?? "").lowercased()]
        return needles.contains { needle in
            haystacks.contains { !$0.isEmpty && $0.contains(needle) }
        }
    }
}

/// Conservative, pure classifier for sensitive focused fields. Accessibility
/// hosts do not always expose native password boxes as `AXSecureTextField`;
/// some only surface a role description or label. A false positive only hides
/// autocomplete, while a false negative could show a secret as ghost text.
enum CotypingSecureFieldDetector {
    static func isSecure(
        role: String?,
        subrole: String?,
        roleDescription: String?,
        title: String?,
        descriptionLabel: String?
    ) -> Bool {
        let markers = [role, subrole, roleDescription, title, descriptionLabel]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
        return markers.contains { marker in
            sensitiveMarkers.contains { marker.contains($0) }
        }
    }

    static let sensitiveMarkers: [String] = [
        "secure",
        "password",
        "passcode",
        "passphrase",
        "cvv",
        "cvc",
        "security code",
        "verification code",
        "one-time code",
        "one time code",
        "social security",
        "card number",
        "credit card",
    ]
}
