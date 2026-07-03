import Foundation

/// Refuses model downloads that can't fit on disk *before* gigabytes move,
/// instead of failing at install time with a cryptic write error. The
/// decision is a pure function of two byte counts so it unit-tests without a
/// filesystem; only `availableBytes(at:)` touches the volume.
enum DiskSpacePrecheck {

    /// Slack required beyond the file itself: install headroom plus a margin
    /// so the download can't be the thing that runs the boot volume dry.
    static let headroomBytes: Int64 = 2_000_000_000

    /// Nil when the download fits, else a user-facing refusal message.
    static func advisory(expectedBytes: Int64?, availableBytes: Int64?) -> String? {
        guard let expectedBytes, expectedBytes > 0, let availableBytes else { return nil }
        guard availableBytes < expectedBytes + headroomBytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let needed = formatter.string(fromByteCount: expectedBytes + headroomBytes)
        let free = formatter.string(fromByteCount: max(0, availableBytes))
        return "Not enough free disk space: this model needs about \(needed) free "
            + "(download plus headroom), but only \(free) is available. "
            + "Free up space or pick a smaller model."
    }

    /// Free capacity of the volume holding `url`, using the "important usage"
    /// figure so purgeable space (local Time Machine snapshots, caches) counts
    /// as available — matching what Finder reports and what the OS will
    /// actually reclaim for a user-initiated download.
    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
