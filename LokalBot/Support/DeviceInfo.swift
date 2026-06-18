import Foundation

/// Snapshots host details for the Settings diagnostics readout: app version,
/// macOS version, Mac model identifier, CPU/chip brand, and installed memory.
///
/// Lives in `Support/` because it owns no lifecycle or actor state — every field
/// is read from bundle metadata or a `sysctlbyname` value with no side effects,
/// so the type is just a namespace of pure functions.
enum DeviceInfo {
    /// One host snapshot. Each field is optional so a missing sysctl key (Rosetta
    /// translation, a future macOS rename) drops out of `summaryLine` rather than
    /// surfacing a literal "unknown" to the user.
    struct Snapshot: Equatable {
        let appVersion: String?
        let macosVersion: String?
        let model: String?
        let chip: String?
        let memoryGB: Int?

        /// Compact, human-readable one-liner for a Settings → Diagnostics row.
        /// Joins only the fields we actually resolved, so the line never carries a
        /// dangling separator or an empty value.
        var summaryLine: String {
            var parts: [String] = []
            if let appVersion { parts.append("v\(appVersion)") }
            if let macosVersion { parts.append("macOS \(macosVersion)") }
            if let model { parts.append(model) }
            if let chip { parts.append(chip) }
            if let memoryGB { parts.append("\(memoryGB) GB") }
            return parts.isEmpty ? "Device information unavailable" : parts.joined(separator: " · ")
        }
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            appVersion: bundleVersion(),
            macosVersion: macosVersionString(),
            model: sysctlString("hw.model"),
            // `machdep.cpu.brand_string` reports the chip on both Apple Silicon
            // ("Apple M3 Pro") and Intel ("Intel(R) Core(TM)…") across every macOS
            // we support, so the field is populated on all hosts we run on.
            chip: sysctlString("machdep.cpu.brand_string"),
            memoryGB: physicalMemoryGB()
        )
    }

    /// User-visible version (CFBundleShortVersionString), falling back to the build
    /// number so a developer build without a marketing version still reads something.
    private static func bundleVersion() -> String? {
        let info = Bundle.main.infoDictionary
        if let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty {
            return short
        }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty {
            return build
        }
        return nil
    }

    /// Short "14.6" / "14.6.1" rather than `operatingSystemVersionString`, which
    /// carries a "Version " prefix and the build number we don't want in the row.
    private static func macosVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.patchVersion == 0 {
            return "\(version.majorVersion).\(version.minorVersion)"
        }
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Reads a C-string sysctl key and trims trailing NUL/whitespace. Returns nil
    /// when the key is missing so the caller can omit the field cleanly.
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Installed RAM rounded to whole GB. Returns nil only if the kernel reports 0.
    private static func physicalMemoryGB() -> Int? {
        let bytes = ProcessInfo.processInfo.physicalMemory
        guard bytes > 0 else { return nil }
        return Int((Double(bytes) / 1_073_741_824.0).rounded())
    }
}
