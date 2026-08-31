import Foundation

struct MeetingLibraryLoad: Sendable {
    struct Issue: Equatable, Sendable {
        let path: String
        let detail: String

        var message: String { "\(path): \(detail)" }
    }

    let meetings: [Meeting]
    let issues: [Issue]
}

private enum StorageManagerError: LocalizedError, Sendable {
    case unavailable(path: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let path, let detail):
            return "The meeting library at \(path) is unavailable: \(detail)"
        }
    }
}

/// Owns the on-disk layout (design doc §6):
/// ~/Library/Application Support/me.dotenv.LokalBot/
///   meetings/YYYY/MM/dd-slug/{mic.m4a, system.m4a, meta.json}
///
/// Rooted at the bundle id, NOT "LokalBot": an unrelated app may own
/// ~/Library/Application Support/LokalBot/ on some machines, and its
/// "Meetings" folder would collide with our "meetings" on the default
/// case-insensitive filesystem.
final class StorageManager {

    let rootURL: URL
    private var preparationError: StorageManagerError?

    init(rootURL: URL = AppDirectories.libraryRoot) {
        // UI-test isolation hook: when the env var points at a directory,
        // every read/write goes there instead of the user's real library.
        // Production launches never set it, so default behaviour is unchanged.
        self.rootURL = rootURL
        do {
            try FileManager.default.createDirectory(
                at: rootURL.appendingPathComponent("meetings"),
                withIntermediateDirectories: true)
            preparationError = nil
        } catch {
            preparationError = .unavailable(path: rootURL.path, detail: error.localizedDescription)
        }
    }

    func createMeetingFolder(title: String, appName: String) throws -> Meeting {
        try ensureReady()
        let now = Date()
        let cal = Calendar.current
        let y = cal.component(.year, from: now)
        let m = String(format: "%02d", cal.component(.month, from: now))
        let d = String(format: "%02d", cal.component(.day, from: now))

        var slug = "\(d)-\(Self.slugify(title))"
        var relative = "meetings/\(y)/\(m)/\(slug)"
        // De-dupe: second Zoom meeting the same day gets "-2", etc.
        var counter = 2
        while try FileSystemSupport.itemExists(at: rootURL.appendingPathComponent(relative)) {
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
        try ensureReady()
        let url = meeting.folderURL(in: self).appendingPathComponent("meta.json")
        try JSONCoding.prettyPrintedISO8601Encoder()
            .encode(meeting)
            .write(to: url, options: .atomic)
    }

    /// Scan the library for meta.json files. Fine for M1; replaced by the
    /// SQLite index in M3.
    func loadMeetingLibrary() throws -> MeetingLibraryLoad {
        try ensureReady()
        let decoder = JSONCoding.iso8601Decoder()
        let meetingsRoot = rootURL.appendingPathComponent("meetings")
        var issues: [MeetingLibraryLoad.Issue] = []
        guard let enumerator = FileManager.default.enumerator(
            at: meetingsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                issues.append(.init(path: url.path, detail: error.localizedDescription))
                return true
            }) else {
            throw StorageManagerError.unavailable(
                path: meetingsRoot.path,
                detail: "the folder could not be enumerated")
        }
        var result: [Meeting] = []
        for case let url as URL in enumerator where url.lastPathComponent == "meta.json" {
            if let meeting = loadMeeting(at: url, decoder: decoder, issues: &issues) {
                result.append(meeting)
            }
        }
        return MeetingLibraryLoad(
            meetings: result.sorted { $0.startedAt > $1.startedAt },
            issues: issues)
    }

    private func loadMeeting(
        at metadataURL: URL,
        decoder: JSONDecoder,
        issues: inout [MeetingLibraryLoad.Issue]
    ) -> Meeting? {
        do {
            let data = try Data(contentsOf: metadataURL)
            var meeting = try decoder.decode(Meeting.self, from: data)
            if repair(&meeting, metadataURL: metadataURL, issues: &issues) {
                saveRepairedMeeting(meeting, metadataURL: metadataURL, issues: &issues)
            }
            return meeting
        } catch {
            issues.append(.init(path: metadataURL.path, detail: error.localizedDescription))
            return nil
        }
    }

    private func repair(
        _ meeting: inout Meeting,
        metadataURL: URL,
        issues: inout [MeetingLibraryLoad.Issue]
    ) -> Bool {
        let folder = metadataURL.deletingLastPathComponent()
        var repaired = repairOrphanedEndDate(&meeting, folder: folder, issues: &issues)
        let hasSystemTrack = MeetingAudioFiles.transcribableURL(for: .system, in: folder) != nil
        if meeting.hasSystemTrack != hasSystemTrack {
            meeting.hasSystemTrack = hasSystemTrack
            repaired = true
        }
        if meeting.recordedDuration == nil,
           let duration = MeetingAudioFiles.longestDuration(in: folder) {
            meeting.recordedDuration = duration
            repaired = true
        }
        return repaired
    }

    private func repairOrphanedEndDate(
        _ meeting: inout Meeting,
        folder: URL,
        issues: inout [MeetingLibraryLoad.Issue]
    ) -> Bool {
        guard meeting.endedAt == nil else { return false }
        let dates = audioURLs(in: folder).compactMap {
            modificationDate(for: $0, issues: &issues)
        }
        meeting.endedAt = dates.max() ?? meeting.startedAt
        return true
    }

    private func audioURLs(in folder: URL) -> [URL] {
        MeetingAudioFiles.Track.allCases.flatMap { track in
            [
                MeetingAudioFiles.primaryURL(for: track, in: folder),
                MeetingAudioFiles.recoveryURL(for: track, in: folder),
            ]
        }
    }

    private func modificationDate(
        for audioURL: URL,
        issues: inout [MeetingLibraryLoad.Issue]
    ) -> Date? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
            return attributes[.modificationDate] as? Date
        } catch where FileSystemSupport.isMissing(error) {
            return nil
        } catch {
            issues.append(.init(
                path: audioURL.path,
                detail: "could not inspect orphaned recording audio: "
                    + error.localizedDescription))
            return nil
        }
    }

    private func saveRepairedMeeting(
        _ meeting: Meeting,
        metadataURL: URL,
        issues: inout [MeetingLibraryLoad.Issue]
    ) {
        do {
            try saveMeta(meeting)
        } catch {
            issues.append(.init(
                path: metadataURL.path,
                detail: "loaded, but automatic metadata repair could not be saved: "
                    + error.localizedDescription))
        }
    }

    /// Delete the durable meeting folder. Callers must only remove the meeting
    /// from in-memory/UI state after this succeeds; swallowing the filesystem
    /// error made failed deletions reappear on the next launch.
    func deleteMeeting(_ meeting: Meeting) throws {
        try ensureReady()
        try FileManager.default.removeItem(at: meeting.folderURL(in: self))
    }

    private func ensureReady() throws {
        guard preparationError != nil else { return }
        do {
            try FileManager.default.createDirectory(
                at: rootURL.appendingPathComponent("meetings"),
                withIntermediateDirectories: true)
            preparationError = nil
        } catch {
            let currentError = StorageManagerError.unavailable(
                path: rootURL.path,
                detail: error.localizedDescription)
            preparationError = currentError
            throw currentError
        }
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
