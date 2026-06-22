import Foundation

/// Owns the on-disk layout (design doc §6):
/// ~/Library/Application Support/com.dotenv.LokalBotV3/
///   meetings/YYYY/MM/dd-slug/{mic.m4a, system.m4a, meta.json}
///
/// Rooted at the bundle id, NOT "LokalBotV3": an unrelated app may own
/// ~/Library/Application Support/LokalBotV3/ on some machines, and its
/// "Meetings" folder would collide with our "meetings" on the default
/// case-insensitive filesystem.
final class StorageManager {

    let rootURL: URL

    init() {
        // UI-test isolation hook: when the env var points at a directory,
        // every read/write goes there instead of the user's real library.
        // Production launches never set it, so default behaviour is unchanged.
        if let override = ProcessInfo.processInfo.environment["LOKALBOTV3_STORAGE_ROOT"],
           !override.isEmpty {
            rootURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first!
            rootURL = appSupport.appendingPathComponent(AppIdentifiers.bundleID, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: rootURL.appendingPathComponent("meetings"),
                                                 withIntermediateDirectories: true)
    }

    func createMeetingFolder(title: String, appName: String) throws -> Meeting {
        let now = Date()
        let cal = Calendar.current
        let y = cal.component(.year, from: now)
        let m = String(format: "%02d", cal.component(.month, from: now))
        let d = String(format: "%02d", cal.component(.day, from: now))

        var slug = "\(d)-\(Self.slugify(title))"
        var relative = "meetings/\(y)/\(m)/\(slug)"
        // De-dupe: second Zoom meeting the same day gets "-2", etc.
        var counter = 2
        while FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(relative).path) {
            slug = "\(d)-\(Self.slugify(title))-\(counter)"
            relative = "meetings/\(y)/\(m)/\(slug)"
            counter += 1
        }

        let folder = rootURL.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let meeting = Meeting(id: UUID(), title: title, appName: appName,
                              startedAt: now, endedAt: nil, relativePath: relative)
        try saveMeta(meeting)
        return meeting
    }

    func saveMeta(_ meeting: Meeting) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = meeting.folderURL(in: self).appendingPathComponent("meta.json")
        try encoder.encode(meeting).write(to: url, options: .atomic)
    }

    /// Scan the library for meta.json files. Fine for M1; replaced by the
    /// SQLite index in M3.
    func loadMeetings() -> [Meeting] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meetingsRoot = rootURL.appendingPathComponent("meetings")
        guard let enumerator = FileManager.default.enumerator(at: meetingsRoot,
                                                              includingPropertiesForKeys: nil) else { return [] }
        var result: [Meeting] = []
        for case let url as URL in enumerator where url.lastPathComponent == "meta.json" {
            if let data = try? Data(contentsOf: url),
               var meeting = try? decoder.decode(Meeting.self, from: data) {
                // Orphan repair: app killed mid-recording leaves endedAt nil
                // forever ("in progress"). Close it at the audio's last write.
                if meeting.endedAt == nil {
                    let mic = url.deletingLastPathComponent().appendingPathComponent("mic.m4a")
                    let mtime = (try? FileManager.default.attributesOfItem(atPath: mic.path))?[.modificationDate] as? Date
                    meeting.endedAt = mtime ?? meeting.startedAt
                    try? saveMeta(meeting)
                }
                result.append(meeting)
            }
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }

    func deleteMeeting(_ meeting: Meeting) {
        try? FileManager.default.removeItem(at: meeting.folderURL(in: self))
    }

    static func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
            .applyingTransform(.stripDiacritics, reverse: false) ?? s.lowercased()
        let allowed = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed).split(separator: "-").joined(separator: "-")
    }
}

extension Meeting {
    /// Resolve this meeting's on-disk folder against a `StorageManager`'s
    /// root. Lives on `StorageManager.swift` (not `Meeting.swift`) so the
    /// embedded `lokalbot-cli` — which doesn't compile `StorageManager` —
    /// keeps the `Meeting` value type dependency-free.
    func folderURL(in storage: StorageManager) -> URL {
        storage.rootURL.appendingPathComponent(relativePath, isDirectory: true)
    }
}
