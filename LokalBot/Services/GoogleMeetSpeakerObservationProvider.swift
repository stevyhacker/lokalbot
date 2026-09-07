import AppKit
import CryptoKit
import ScreenCaptureKit

struct MeetingSpeakerObservationBatch: Sendable {
    var sourceKey: String
    var observations: [ParticipantObservation]
    var reason: String?
}

@MainActor protocol MeetingSpeakerObservationProvider: AnyObject {
    func observe(config: AppSettings, expectedMeetingURL: URL?, capturedBundleID: String, visual: Bool) async -> MeetingSpeakerObservationBatch
    func stop() async
}

@MainActor final class GoogleMeetSpeakerObservationProvider: MeetingSpeakerObservationProvider {
    private let reader = MeetingParticipantAccessibilityReader()
    private let frames = MeetingSpeakerFrameSource()
    private let monitor = MeetingSpeakerSourceMonitor()
    private var boundURL: String?
    private var lastFrameTime: Double = 0
    private var verifiedNames: [String: Double] = [:]

    nonisolated static func meetURL(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw), components.scheme == "https",
              components.host?.lowercased() == "meet.google.com", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              components.path.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil else { return nil }
        return "https://meet.google.com" + components.path
    }

    nonisolated static func sourceAllowed(snapshot: MeetingParticipantSnapshot, config: AppSettings, expectedURL: String?) -> Bool {
        guard let url = meetURL(snapshot.url), expectedURL == nil || expectedURL == url,
              !ScreenContextPrivacy.isPrivateWindow(title: snapshot.title),
              !ScreenContextPrivacy.isExcluded(sourceURL: url, rules: config.excludedScreenDomainList),
              !ScreenshotCaptureLayout.isExcluded(appName: "Google Chrome", excludedApps: config.excludedAppList),
              !snapshot.otherAudibleTabs,
              snapshot.hostEnd - snapshot.hostStart <= 0.25 else { return false }
        return true
    }

    private func unavailable(_ reason: String) -> MeetingSpeakerObservationBatch {
        MeetingSpeakerObservationBatch(sourceKey: "", observations: [], reason: reason)
    }

    func observe(config: AppSettings, expectedMeetingURL: URL?, capturedBundleID: String, visual: Bool) async -> MeetingSpeakerObservationBatch {
        guard capturedBundleID == "com.google.Chrome",
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.google.Chrome" else {
            await frames.stop()
            return unavailable("Bring the recorded Google Meet tab to the front")
        }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              (session["CGSSessionScreenIsLocked"] as? Bool) != true,
              (session[kCGSessionOnConsoleKey as String] as? Bool) == true else {
            await frames.stop()
            return unavailable("Screen is locked or unavailable")
        }
        monitor.start(processID: app.processIdentifier)
        let sourceRevision = monitor.revision
        guard let before = await reader.capture(processID: app.processIdentifier),
              monitor.revision == sourceRevision,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              Self.sourceAllowed(snapshot: before, config: config,
                expectedURL: boundURL ?? expectedMeetingURL.flatMap { Self.meetURL($0.absoluteString) }) else {
            await frames.stop()
            return unavailable("Meet source or Accessibility permission unavailable")
        }
        if boundURL == nil { boundURL = before.url }
        let source = Self.digest("\(app.processIdentifier)|\(before.url)|\(before.title)|\(before.windowFrame)|\(sourceRevision)")
        guard visual else { return .init(sourceKey: source, observations: [], reason: nil) }
        guard !before.tiles.isEmpty, before.tiles.count <= 60 else {
            await frames.stop()
            return .init(sourceKey: source, observations: [], reason: "Speaker name suggestions unavailable for this layout")
        }
        let epoch = Self.digest(before.tiles.map { "\($0.name)|\($0.frame)" }.sorted().joined(separator: "|"))
        let duplicates = Dictionary(grouping: before.tiles, by: { ParticipantObservation.nameKey($0.name) })
        var tiles = before.tiles
        var frameTime: Double?
        if tiles.contains(where: { $0.speaking == nil }) {
            guard CGPreflightScreenCaptureAccess() else {
                return .init(sourceKey: source, observations: [], reason: "Screen Recording permission needed for visual indicators")
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let matching = content.windows.filter {
                    $0.owningApplication?.processID == app.processIdentifier && $0.title == before.title
                        && abs($0.frame.minX - before.windowFrame.minX) < 3 && abs($0.frame.minY - before.windowFrame.minY) < 3
                        && abs($0.frame.width - before.windowFrame.width) < 3
                }
                guard matching.count == 1, let window = matching.first else { return unavailable("Meet window changed") }
                try await frames.start(window: window)
                guard let frame = frames.frame(), frame.hostTime > lastFrameTime,
                      abs(RecordingAudioClock.now - frame.hostTime) < 0.75 else {
                    return .init(sourceKey: source, observations: [], reason: "Waiting for a fresh participant frame")
                }
                lastFrameTime = frame.hostTime
                frameTime = frame.hostTime
                for index in tiles.indices where tiles[index].speaking == nil {
                    let tile = tiles[index]
                    let cacheKey = epoch + "|" + tile.name
                    let verify = (verifiedNames[cacheKey] ?? 0) < frame.hostTime - 5
                    let active = await Task.detached(priority: .utility) { [frames] in
                        frames.activeTile(tile, in: frame, window: before.windowFrame, verifyName: verify)
                    }.value
                    if active && verify { verifiedNames[cacheKey] = frame.hostTime }
                    tiles[index].speaking = active
                }
                if verifiedNames.count > 120 { verifiedNames = verifiedNames.filter { $0.value > frame.hostTime - 5 } }
            } catch { return unavailable("Participant frame capture unavailable") }
        }
        // Revalidate after OCR and capture, never publish a result from a tab
        // that became hidden/private while its pixels were being processed.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              monitor.revision == sourceRevision,
              let after = await reader.capture(processID: app.processIdentifier),
              after.url == before.url, after.title == before.title, after.windowFrame == before.windowFrame,
              Self.sourceAllowed(snapshot: after, config: config, expectedURL: boundURL),
              before.tiles == after.tiles, monitor.revision == sourceRevision,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return unavailable("Meet source changed during observation") }
        let now = frameTime ?? (before.hostStart + before.hostEnd) / 2
        let uncertainty = frameTime == nil ? (before.hostEnd - before.hostStart) / 2 : 0.025
        let observations = tiles.map { tile in
            ParticipantObservation(reference: Self.digest(ParticipantObservation.nameKey(tile.name)), displayName: tile.name,
                layoutEpoch: epoch, hostStart: now - uncertainty, hostEnd: now + max(uncertainty, 0.001),
                active: tile.speaking == true, muted: tile.muted, isSelf: tile.isSelf,
                unique: !tile.sharedRoom && duplicates[ParticipantObservation.nameKey(tile.name)]?.count == 1)
        }
        return .init(sourceKey: source, observations: observations, reason: nil)
    }

    nonisolated private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    func stop() async { monitor.stop(); lastFrameTime = 0; verifiedNames = [:]; await frames.stop() }
}
