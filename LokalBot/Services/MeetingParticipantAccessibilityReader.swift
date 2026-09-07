import AppKit
import ApplicationServices
import Foundation

struct MeetingParticipantTile: Equatable, Sendable {
    var name: String
    var frame: CGRect
    var speaking: Bool?
    var muted: Bool
    var isSelf: Bool
    var sharedRoom = false
}

struct MeetingParticipantSnapshot: Sendable {
    var processID: pid_t
    var title: String
    var url: String
    var windowFrame: CGRect
    var tiles: [MeetingParticipantTile]
    var hostStart: Double
    var hostEnd: Double
    var otherAudibleTabs = false
}

/// Separate bounded reader: generic screen OCR never becomes a tile identity.
final class MeetingParticipantAccessibilityReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lokalbot.meeting-speaker.ax", qos: .utility)
    private let lock = NSLock()
    private var busy = false
    private func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        return true
    }
    private func release() { lock.lock(); busy = false; lock.unlock() }

    func capture(processID: pid_t) async -> MeetingParticipantSnapshot? {
        guard AXIsProcessTrusted(), claim() else { return nil }
        return await withCheckedContinuation { continuation in
            let delivery = Delivery(continuation)
            queue.async { [self] in
                let result = Self.resolve(processID)
                release()
                delivery.finish(result)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { delivery.finish(nil) }
        }
    }

    private final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<MeetingParticipantSnapshot?, Never>?
        init(_ continuation: CheckedContinuation<MeetingParticipantSnapshot?, Never>) { self.continuation = continuation }
        func finish(_ value: MeetingParticipantSnapshot?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        (value(element, attribute) as? String) ?? ""
    }
    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(parent, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
    private static func bounds(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions), dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    /// Only an explicitly participant-labelled container establishes a tile.
    /// Unknown/localized provider structures return unavailable until verified.
    static func tileName(description: String) -> String? {
        for suffix in ["'s tile", "’s tile", "'s video", "’s video"] where description.hasSuffix(suffix) {
            return ParticipantObservation.safeName(String(description.dropLast(suffix.count)))
        }
        return nil
    }

    private static func resolve(_ processID: pid_t) -> MeetingParticipantSnapshot? {
        let start = RecordingAudioClock.now
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.012)
        guard let window = element(application, kAXFocusedWindowAttribute),
              (value(window, kAXMinimizedAttribute) as? Bool) != true,
              let frame = bounds(window) else { return nil }
        let title = string(window, kAXTitleAttribute)
        guard !ScreenContextPrivacy.isPrivateWindow(title: title) else { return nil }
        if let focused = element(application, kAXFocusedUIElementAttribute),
           string(focused, kAXSubroleAttribute) == "AXSecureTextField" { return nil }
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var count = 0
        var urls: Set<String> = []
        var tiles: [MeetingParticipantTile] = []
        var otherAudibleTabs = false
        while let (node, depth) = stack.popLast() {
            count += 1
            guard count <= 600, RecordingAudioClock.now - start <= 0.20 else { return nil }
            let role = string(node, kAXRoleAttribute)
            if role == "AXWebArea" {
                let raw = value(node, kAXURLAttribute)
                let url = (raw as? URL)?.absoluteString ?? (raw as? String) ?? string(node, kAXDocumentAttribute)
                if let valid = GoogleMeetSpeakerObservationProvider.meetURL(url) { urls.insert(valid) } else { return nil }
            }
            let description = string(node, kAXDescriptionAttribute)
            if ["AXRadioButton", "AXTab"].contains(role),
               description.localizedCaseInsensitiveContains("audio playing"),
               (value(node, kAXSelectedAttribute) as? Bool) != true {
                otherAudibleTabs = true
            }
            let children = (value(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            if let name = tileName(description: description), let tileFrame = bounds(node), frame.contains(tileFrame) {
                var labels = [description]
                for child in children.prefix(24) {
                    labels.append(string(child, kAXDescriptionAttribute))
                    labels.append(string(child, kAXTitleAttribute))
                }
                let speaking = labels.contains("\(name) is speaking") || labels.contains("Speaking: \(name)")
                let silent = labels.contains("\(name) is not speaking")
                tiles.append(MeetingParticipantTile(name: name, frame: tileFrame,
                    speaking: speaking ? true : (silent ? false : nil),
                    muted: labels.contains("\(name)'s microphone is off") || labels.contains("Microphone off"),
                    isSelf: labels.contains("Your tile") || labels.contains("You"),
                    sharedRoom: labels.contains("Conference room") || labels.contains("Meeting room")
                        || name.lowercased().range(of: #"\b(room|boardroom)\b| & | and "#, options: .regularExpression) != nil))
            }
            if depth < 18 { stack += children.prefix(100).map { ($0, depth + 1) } }
        }
        guard urls.count == 1, let url = urls.first,
              let stillFocused = element(application, kAXFocusedWindowAttribute), CFEqual(window, stillFocused) else { return nil }
        return MeetingParticipantSnapshot(processID: processID, title: title, url: url, windowFrame: frame,
            tiles: tiles, hostStart: start, hostEnd: RecordingAudioClock.now, otherAudibleTabs: otherAudibleTabs)
    }
}
