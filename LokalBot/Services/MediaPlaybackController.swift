import AppKit
import Foundation
import IOKit

enum MediaPlaybackController {
    @MainActor
    @discardableResult
    static func pauseActiveMediaPlayers(reason: String) -> [String] {
        let targets = activePauseTargets()
        guard !targets.isEmpty else { return [] }

        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var paused: Set<String> = []

        if targets.contains(where: \.requiresMediaKeyFallback),
           postPlayPauseMediaKey() {
            for target in targets where target.requiresMediaKeyFallback {
                paused.formUnion(target.processNames)
            }
        }

        for target in targets {
            guard runningBundleIDs.contains(target.controlBundleID),
                  pauseScript(for: target.controlBundleID) != nil else { continue }
            if runPauseScript(for: target.controlBundleID) {
                paused.formUnion(target.processNames)
            }
        }

        let names = paused.sorted()
        if !names.isEmpty {
            lokalbotLog("media paused for \(reason): \(names.joined(separator: ", "))")
        }
        return names
    }

    private static func activePauseTargets() -> [PauseTarget] {
        let processes = (try? CoreAudioUtils.listAudioProcesses()) ?? []
        var targetsByBundleID: [String: PauseTarget] = [:]

        for process in processes {
            guard process.isRunningOutput,
                  let bundleID = process.bundleID,
                  let controlBundleID = controllableMediaBundleID(forAudioBundleID: bundleID)
            else { continue }

            var target = targetsByBundleID[controlBundleID]
                ?? PauseTarget(controlBundleID: controlBundleID)
            target.processNames.insert(process.name)
            target.requiresMediaKeyFallback = target.requiresMediaKeyFallback
                || requiresMediaKeyFallback(controlBundleID: controlBundleID)
            targetsByBundleID[controlBundleID] = target
        }

        return targetsByBundleID.values.sorted { $0.controlBundleID < $1.controlBundleID }
    }

    private static func controllableMediaBundleID(forAudioBundleID bundleID: String) -> String? {
        if let mediaBundleID = mediaHostBundleID(forAudioBundleID: bundleID) {
            return mediaBundleID
        }
        if let browserBundleID = MeetingDetector.hostBrowserBundleID(forAudioBundleID: bundleID) {
            return browserBundleID
        }
        return nil
    }

    private static func mediaHostBundleID(forAudioBundleID bundleID: String) -> String? {
        if AudioSourceMonitor.isMediaPlayer(bundleID) { return bundleID }

        let normalizedBundleID = bundleID.lowercased()
        return AudioSourceMonitor.mediaBundleIDs.first { mediaBundleID in
            normalizedBundleID.hasPrefix("\(mediaBundleID.lowercased()).")
        }
    }

    private static func requiresMediaKeyFallback(controlBundleID: String) -> Bool {
        MeetingDetector.browsers.contains(controlBundleID)
            || pauseScript(for: controlBundleID) == nil
    }

    private static func runPauseScript(for bundleID: String) -> Bool {
        guard let source = pauseScript(for: bundleID),
              let script = NSAppleScript(source: source) else {
            return false
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            lokalbotLog("media pause failed bundle=\(bundleID) error=\(error)")
            return false
        }
        return true
    }

    private static func postPlayPauseMediaKey() -> Bool {
        let keyCode = NX_KEYTYPE_PLAY
        let keyDownData = (keyCode << 16) | (0xA << 8)
        let keyUpData = (keyCode << 16) | (0xB << 8)

        guard let keyDown = mediaKeyEvent(data1: keyDownData)?.cgEvent,
              let keyUp = mediaKeyEvent(data1: keyUpData)?.cgEvent else {
            return false
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func mediaKeyEvent(data1: Int32) -> NSEvent? {
        NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(0xA00)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
            data1: Int(data1),
            data2: -1)
    }

    private static func pauseScript(for bundleID: String) -> String? {
        switch bundleID {
        case "com.spotify.client":
            """
            tell application id "com.spotify.client"
                if player state is playing then pause
            end tell
            """
        case "com.apple.Music",
             "com.apple.iTunes",
             "com.apple.podcasts",
             "com.apple.TV",
             "org.videolan.vlc":
            """
            tell application id "\(bundleID)" to pause
            """
        case "com.apple.QuickTimePlayerX":
            """
            tell application id "com.apple.QuickTimePlayerX"
                repeat with openMovie in documents
                    try
                        pause openMovie
                    end try
                end repeat
            end tell
            """
        case "com.google.Chrome",
             "com.microsoft.edgemac",
             "com.brave.Browser",
             "company.thebrowser.Browser":
            """
            tell application id "\(bundleID)"
                repeat with browserWindow in windows
                    repeat with browserTab in tabs of browserWindow
                        try
                            execute browserTab javascript "\(pauseHTMLMediaJavaScript)"
                        end try
                    end repeat
                end repeat
            end tell
            """
        case "com.apple.Safari":
            """
            tell application id "com.apple.Safari"
                repeat with browserWindow in windows
                    repeat with browserTab in tabs of browserWindow
                        try
                            do JavaScript "\(pauseHTMLMediaJavaScript)" in browserTab
                        end try
                    end repeat
                end repeat
            end tell
            """
        default:
            nil
        }
    }

    private static let pauseHTMLMediaJavaScript = """
    (() => { for (const node of document.querySelectorAll('audio, video')) { try { node.pause(); } catch (_) {} } })()
    """

    private struct PauseTarget {
        let controlBundleID: String
        var processNames: Set<String> = []
        var requiresMediaKeyFallback = false
    }
}
