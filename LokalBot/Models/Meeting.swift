import Foundation

/// One recorded meeting. Persisted as `meta.json` inside its own folder:
/// `meetings/YYYY/MM/dd-slug/{mic.m4a, system.m4a, meta.json}`.
struct Meeting: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var appName: String
    var startedAt: Date
    var endedAt: Date?
    /// Path relative to the LokalBotV3 storage root, e.g. "meetings/2026/06/10-zoom-meeting".
    var relativePath: String
    var hasSystemTrack: Bool = false

    // MARK: Calendar provenance (optional)
    //
    // Populated only when a recording was matched to a calendar event. All
    // optional so `meta.json` written before calendar support still decodes
    // (synthesized `Codable` decodes missing keys to nil and omits nil keys on
    // encode, so manual recordings keep their old, calendar-free shape).
    var calendarProvider: String?
    var calendarEventID: String?
    var calendarTitle: String?
    var scheduledStartAt: Date?
    var scheduledEndAt: Date?
    var meetingURL: URL?
    /// Calendar attendee / roster names that can seed speaker rename
    /// suggestions. Optional so older `meta.json` files still decode.
    var participantNameHints: [String]?

    /// Length of the actual recorded audio (longest track), measured at
    /// finalize. The wall-clock span (`duration`) can exceed what was captured
    /// — an audio-device disruption can truncate the tracks while a
    /// calendar-backed session stays live — so this is the playable length and
    /// what `durationLabel` reports. Optional so older `meta.json` still decodes.
    var recordedDuration: TimeInterval?

    var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }


    var durationLabel: String {
        guard let d = recordedDuration ?? duration else { return "in progress" }
        let m = Int(d) / 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m) min"
    }
}
