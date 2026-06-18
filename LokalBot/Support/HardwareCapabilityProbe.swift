import Foundation

/// Installed memory + CPU architecture, read once so model-fit messaging in
/// onboarding/Settings can recommend or warn about a model before the user
/// downloads gigabytes. Split from the view as a tiny seam: `ModelFit.evaluate`
/// stays a pure function of a `HardwareCapability` value and is unit-testable
/// with synthetic hardware (no device required).
struct HardwareCapability: Equatable {
    let physicalMemoryBytes: UInt64
    let isAppleSilicon: Bool
}

enum HardwareCapabilityProbe {
    static func current() -> HardwareCapability {
        HardwareCapability(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            isAppleSilicon: isAppleSilicon
        )
    }

    /// Compile-time architecture is enough: we ship a universal binary and only
    /// need to tell Apple Silicon from Intel for advisory copy. A Rosetta run
    /// reporting x86_64 is an acceptably conservative misread for that purpose.
    private static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}

/// How well a model of a given on-disk size fits the host's installed RAM.
/// Pure value logic: `evaluate` depends only on its arguments, so it can be
/// exercised across the whole RAM range in tests without touching hardware.
enum ModelFit: Equatable {
    case comfortable
    case tight
    case tooLarge

    /// Heuristic fit. A local LLM needs roughly its file size plus ~30% headroom
    /// (KV cache, context, runtime) resident, so we budget `modelSizeGB * 1.3` and
    /// compare that requirement against installed RAM:
    ///   - ≤ 60% of RAM → comfortable
    ///   - 60%–80% of RAM → tight (works, but crowds everything else)
    ///   - > 80% of RAM → tooLarge (likely to swap hard or fail to load)
    static func evaluate(modelSizeGB: Double, capability: HardwareCapability) -> ModelFit {
        let ramGB = Double(capability.physicalMemoryBytes) / 1_073_741_824.0
        let requiredGB = max(0, modelSizeGB) * 1.3
        if requiredGB <= ramGB * 0.6 {
            return .comfortable
        }
        if requiredGB <= ramGB * 0.8 {
            return .tight
        }
        return .tooLarge
    }

    /// Short status word for a picker row.
    var label: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .tight: return "Tight"
        case .tooLarge: return "Too large"
        }
    }

    /// One-line guidance shown beneath the label, or nil when no caveat applies.
    var advisory: String? {
        switch self {
        case .comfortable:
            return nil
        case .tight:
            return "Uses most of your memory — close other apps for the best speed."
        case .tooLarge:
            return "Likely too large for this Mac's memory; it may run very slowly or fail to load."
        }
    }
}
