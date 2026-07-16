import CoreGraphics

/// Pure transition rule for the permission helper floating over System Settings.
/// The controller polls often, so unchanged state must collapse to `.none` to
/// avoid repeatedly ordering the panel and making it flicker.
nonisolated enum PermissionOverlayTracker {
    nonisolated enum Transition: Equatable {
        case present
        case reposition
        case hide
        case none
    }

    static func transition(
        settingsFrame: CGRect?,
        hasPresented: Bool,
        isVisible: Bool,
        lastFrame: CGRect?
    ) -> Transition {
        guard let settingsFrame else {
            return isVisible ? .hide : .none
        }

        guard hasPresented else {
            return .present
        }

        if !isVisible || settingsFrame != lastFrame {
            return .reposition
        }

        return .none
    }
}
