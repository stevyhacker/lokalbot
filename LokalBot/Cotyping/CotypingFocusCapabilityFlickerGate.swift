import Foundation

/// Suppresses a single `supported -> blocked -> supported` focus poll on the
/// same editable element. Some host apps briefly publish a non-empty selection
/// while redrawing the caret; without this, the ghost overlay tears down and
/// rebuilds even though focus did not really leave the field.
struct CotypingFocusCapabilityFlickerGate: Sendable {
    static let requiredConsecutiveBlockedReads = 2

    nonisolated enum Decision: Equatable, Sendable {
        case apply
        case suppress(pendingBlockedReadCount: Int)
    }

    private var lastDeliveredSupportedIdentity: String?
    private var consecutiveBlockedReadCount = 0

    mutating func evaluate(_ focus: CotypingFocus) -> Decision {
        switch focus.capability {
        case .supported:
            lastDeliveredSupportedIdentity = focus.field?.focusIdentityKey ?? focus.focusIdentityKey
            consecutiveBlockedReadCount = 0
            return .apply

        case .blocked(let reason):
            guard Self.isSmoothableBlockedReason(reason),
                  let lastIdentity = lastDeliveredSupportedIdentity,
                  let currentIdentity = focus.focusIdentityKey ?? focus.field?.focusIdentityKey,
                  currentIdentity == lastIdentity else {
                lastDeliveredSupportedIdentity = nil
                consecutiveBlockedReadCount = 0
                return .apply
            }

            consecutiveBlockedReadCount += 1
            if consecutiveBlockedReadCount >= Self.requiredConsecutiveBlockedReads {
                lastDeliveredSupportedIdentity = nil
                consecutiveBlockedReadCount = 0
                return .apply
            }
            return .suppress(pendingBlockedReadCount: consecutiveBlockedReadCount)

        case .unsupported:
            lastDeliveredSupportedIdentity = nil
            consecutiveBlockedReadCount = 0
            return .apply
        }
    }

    /// Never smooth secure-field blocks: privacy beats visual stability. Today
    /// the only editable blocked state that is safe to smooth is selected text.
    nonisolated static func isSmoothableBlockedReason(_ reason: String) -> Bool {
        reason == "Text selected."
    }
}
