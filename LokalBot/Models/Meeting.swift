import Foundation

/// One recorded meeting. Persisted as `meta.json` inside its own folder:
/// `meetings/YYYY/MM/dd-slug/{mic.m4a, system.m4a, meta.json}`.
struct Meeting: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var appName: String
    var startedAt: Date
    var endedAt: Date?
    /// Path relative to the BotinaV2 storage root, e.g. "meetings/2026/06/10-zoom-meeting".
    var relativePath: String
    var hasSystemTrack: Bool = false

    var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }


    var durationLabel: String {
        guard let d = duration else { return "in progress" }
        let m = Int(d) / 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m) min"
    }
}
