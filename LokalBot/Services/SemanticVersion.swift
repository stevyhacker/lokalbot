import Foundation

/// A minimal SemVer-style version (`MAJOR.MINOR.PATCH` with an optional
/// `-prerelease` suffix) used to compare the running build against the
/// latest GitHub release.
///
/// Parsing is deliberately lenient about the things release tags vary on:
/// a leading `v`, missing minor/patch components, surrounding whitespace,
/// and `+build` metadata are all tolerated. Ordering, however, is strict
/// SemVer — numeric (so `0.1.1 < 0.1.10`, never lexical) with full
/// pre-release precedence (`1.0.0-beta < 1.0.0`).
struct SemanticVersion: Equatable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// Dot-separated pre-release identifiers, empty for a normal release.
    /// e.g. `["beta", "2"]` for `1.0.0-beta.2`.
    let prerelease: [String]

    init?(_ rawString: String) {
        var string = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }

        // Tolerate a leading "v"/"V" — GitHub tags are usually `vX.Y.Z`.
        if let first = string.first, first == "v" || first == "V" {
            string.removeFirst()
        }

        // Build metadata (everything from the first "+") is ignored per SemVer §10.
        if let plus = string.firstIndex(of: "+") {
            string = String(string[..<plus])
        }

        // Split the core triple from the pre-release segment at the first "-".
        let core: Substring
        let prereleaseSegment: Substring?
        if let dash = string.firstIndex(of: "-") {
            core = string[..<dash]
            prereleaseSegment = string[string.index(after: dash)...]
        } else {
            core = string[...]
            prereleaseSegment = nil
        }

        // 1–3 numeric core components; any omitted trailing component defaults to 0.
        let components = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return nil }
        var numbers = [0, 0, 0]
        for (index, component) in components.enumerated() {
            guard let value = Int(component), value >= 0 else { return nil }
            numbers[index] = value
        }
        self.major = numbers[0]
        self.minor = numbers[1]
        self.patch = numbers[2]

        if let prereleaseSegment {
            // A "-" was present, so a non-empty pre-release is required: a bare
            // "1.0.0-", or any empty identifier like "1.0.0-alpha..1", is
            // malformed and must be rejected — never silently parsed as stable.
            guard !prereleaseSegment.isEmpty else { return nil }
            let identifiers = prereleaseSegment
                .split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)
            guard !identifiers.contains(where: \.isEmpty) else { return nil }
            self.prerelease = identifiers
        } else {
            self.prerelease = []
        }
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : "\(core)-\(prerelease.joined(separator: "."))"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // Equal cores: a version *with* a pre-release ranks below one without it.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false   // 1.0.0  >  1.0.0-beta
        case (false, true): return true    // 1.0.0-beta  <  1.0.0
        case (false, false): return Self.comparePrerelease(lhs.prerelease, rhs.prerelease)
        }
    }

    /// Pre-release precedence per SemVer §11.4: compare identifiers left to
    /// right; numeric identifiers compare numerically and always rank below
    /// alphanumeric ones; if all shared identifiers are equal, the shorter
    /// set ranks lower.
    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            switch (Int(left), Int(right)) {
            case let (l?, r?): return l < r
            case (_?, nil): return true     // numeric < alphanumeric
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.count < rhs.count
    }
}
