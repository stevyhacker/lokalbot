import Foundation

/// One recorded meeting. Persisted as `meta.json` inside its own folder:
/// `meetings/YYYY/MM/dd-slug/{mic.m4a, system.m4a, meta.json}`.
struct Meeting: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var appName: String
    var startedAt: Date
    var endedAt: Date?
    /// Path relative to the LokalBot storage root, e.g. "meetings/2026/06/10-zoom-meeting".
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

    /// Human title hierarchy shared by list, preview, Today, Timeline, Ask,
    /// and Agent surfaces. Calendar provenance beats generic recorder labels;
    /// otherwise preserve the original title and fall back to app + time.
    var displayTitle: String {
        let cleanedTitle = Self.cleanedTitle(title)
        if !Self.isGenericTitle(cleanedTitle) { return cleanedTitle }
        let cleanedCalendar = Self.cleanedTitle(calendarTitle ?? "")
        if !cleanedCalendar.isEmpty { return cleanedCalendar }
        if !cleanedTitle.isEmpty, cleanedTitle.caseInsensitiveCompare("Meeting") != .orderedSame {
            return cleanedTitle
        }
        let app = Self.cleanedTitle(appName)
        let time = startedAt.formatted(date: .omitted, time: .shortened)
        return app.isEmpty ? "Meeting at \(time)" : "\(app) at \(time)"
    }

    private static func cleanedTitle(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isGenericTitle(_ value: String) -> Bool {
        guard !value.isEmpty else { return true }
        let normalized = value.lowercased()
        return normalized == "meeting"
            || normalized == "manual recording"
            || normalized == "recording"
            || normalized == "untitled meeting"
            || normalized.hasPrefix("meeting ")
    }
}
