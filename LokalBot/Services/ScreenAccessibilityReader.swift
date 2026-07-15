import AppKit
import ApplicationServices
import Foundation

struct ScreenAccessibilitySnapshot: Equatable, Sendable {
    var text: String
    var sourceURL: String?
    var documentName: String?
    var focusedSecureField: Bool
}

struct ScreenAccessibilityCaptureResult: Equatable, Sendable {
    var snapshot: ScreenAccessibilitySnapshot?
    var timedOut: Bool

    static let timeout = Self(snapshot: nil, timedOut: true)
}

/// A bounded, single-flight reader for visible Accessibility text. Cross-process
/// AX calls never run on the main actor, and a wedged target can occupy only one
/// worker rather than creating an unbounded queue of blocked snapshots.
final class ScreenAccessibilityReader: @unchecked Sendable {
    typealias Resolver = @Sendable (pid_t) -> ScreenAccessibilitySnapshot?

    static let shared = ScreenAccessibilityReader()
    static let defaultDeadlineMilliseconds = 180
    static let perElementMessagingTimeout: Float = 0.025

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<ScreenAccessibilityCaptureResult, Never>
    }

    private struct Work {
        let id: UInt64
        let processID: pid_t
        var waiters: [UInt64: Waiter]
    }

    private let stateQueue = DispatchQueue(label: "me.dotenv.LokalBot.screen-ax-state")
    private let workerQueue = DispatchQueue(
        label: "me.dotenv.LokalBot.screen-ax-worker",
        qos: .utility)
    private let deadlineMilliseconds: Int
    private let resolver: Resolver
    private var nextIdentifier: UInt64 = 0
    private var active: Work?

    init(
        deadlineMilliseconds: Int = defaultDeadlineMilliseconds,
        resolver: @escaping Resolver = { processID in
            ScreenAccessibilityReader.resolve(processID: processID)
        }
    ) {
        self.deadlineMilliseconds = max(1, deadlineMilliseconds)
        self.resolver = resolver
    }

    func capture(processID: pid_t) async -> ScreenAccessibilityCaptureResult {
        guard processID > 0, AXIsProcessTrusted() else {
            return .init(snapshot: nil, timedOut: false)
        }
        return await withCheckedContinuation { continuation in
            stateQueue.async { [self] in
                nextIdentifier &+= 1
                let waiter = Waiter(id: nextIdentifier, continuation: continuation)
                enqueue(waiter: waiter, processID: processID)
                stateQueue.asyncAfter(
                    deadline: .now() + .milliseconds(deadlineMilliseconds)
                ) { [weak self] in
                    self?.expire(waiterID: waiter.id)
                }
            }
        }
    }

    private func enqueue(waiter: Waiter, processID: pid_t) {
        if var active {
            guard active.processID == processID else {
                waiter.continuation.resume(returning: .timeout)
                return
            }
            active.waiters[waiter.id] = waiter
            self.active = active
            return
        }

        nextIdentifier &+= 1
        let work = Work(
            id: nextIdentifier,
            processID: processID,
            waiters: [waiter.id: waiter])
        active = work
        workerQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = resolver(processID)
            stateQueue.async { [weak self] in
                self?.finish(workID: work.id, snapshot: snapshot)
            }
        }
    }

    private func expire(waiterID: UInt64) {
        guard var active, let waiter = active.waiters.removeValue(forKey: waiterID) else { return }
        self.active = active
        waiter.continuation.resume(returning: .timeout)
    }

    private func finish(workID: UInt64, snapshot: ScreenAccessibilitySnapshot?) {
        guard let completed = active, completed.id == workID else { return }
        active = nil
        let result = ScreenAccessibilityCaptureResult(snapshot: snapshot, timedOut: false)
        for waiter in completed.waiters.values {
            waiter.continuation.resume(returning: result)
        }
    }

    static func resolve(processID: pid_t) -> ScreenAccessibilitySnapshot? {
        guard AXIsProcessTrusted(), processID > 0 else { return nil }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, perElementMessagingTimeout)
        guard let window = elementAttribute(app, kAXFocusedWindowAttribute as String) else {
            return nil
        }

        let focused = elementAttribute(app, kAXFocusedUIElementAttribute as String)
        let focusedSecureField = focused.map(isSecureField) ?? false

        var queue: [AXUIElement] = [window]
        var visited = Set<CFHashCode>()
        var parts: [String] = []
        var seenText = Set<String>()
        var sourceURL: String?
        var document: String?
        var totalCharacters = 0
        let started = ContinuousClock.now
        let maximumDuration = Duration.milliseconds(140)
        let maximumNodes = 320
        let maximumCharacters = 24_000

        while !queue.isEmpty,
              visited.count < maximumNodes,
              totalCharacters < maximumCharacters,
              started.duration(to: .now) < maximumDuration {
            let element = queue.removeFirst()
            let identity = CFHash(element)
            guard visited.insert(identity).inserted else { continue }
            AXUIElementSetMessagingTimeout(element, perElementMessagingTimeout)

            let secure = isSecureField(element)
            if !secure {
                for attribute in [
                    kAXTitleAttribute as String,
                    kAXDescriptionAttribute as String,
                    kAXHelpAttribute as String,
                    kAXValueAttribute as String,
                    kAXSelectedTextAttribute as String,
                ] {
                    guard let text = textualAttribute(element, attribute) else { continue }
                    append(
                        text,
                        parts: &parts,
                        seen: &seenText,
                        totalCharacters: &totalCharacters,
                        maximumCharacters: maximumCharacters)
                }
            }

            if sourceURL == nil {
                sourceURL = urlString(attribute(element, kAXURLAttribute as String))
            }
            if document == nil {
                document = textualValue(attribute(element, kAXDocumentAttribute as String))
            }
            if let children = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(80))
            }
        }

        let text = parts.joined(separator: "\n")
        return ScreenAccessibilitySnapshot(
            text: text,
            sourceURL: ScreenContextPrivacy.sanitizedURL(sourceURL),
            documentName: ScreenContextPrivacy.sanitizedDocumentName(document),
            focusedSecureField: focusedSecureField)
    }

    private static func append(
        _ raw: String,
        parts: inout [String],
        seen: inout Set<String>,
        totalCharacters: inout Int,
        maximumCharacters: Int
    ) {
        let value = raw
            .replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 8_000, seen.insert(value).inserted else { return }
        let remaining = maximumCharacters - totalCharacters
        guard remaining > 0 else { return }
        let clipped = String(value.prefix(remaining))
        parts.append(clipped)
        totalCharacters += clipped.count
    }

    private static func isSecureField(_ element: AXUIElement) -> Bool {
        let role = textualAttribute(element, kAXRoleAttribute as String) ?? ""
        let subrole = textualAttribute(element, kAXSubroleAttribute as String)
        return CotypingSecureFieldDetector.isSecure(
            role: role,
            subrole: subrole,
            roleDescription: textualAttribute(element, kAXRoleDescriptionAttribute as String),
            title: textualAttribute(element, kAXTitleAttribute as String),
            descriptionLabel: textualAttribute(element, kAXDescriptionAttribute as String))
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let raw = attribute(element, name),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func textualAttribute(_ element: AXUIElement, _ name: String) -> String? {
        textualValue(attribute(element, name))
    }

    private static func textualValue(_ value: CFTypeRef?) -> String? {
        switch value {
        case let string as String:
            return string
        case let attributed as NSAttributedString:
            return attributed.string
        case let url as URL:
            return url.absoluteString
        default:
            return nil
        }
    }

    private static func urlString(_ value: CFTypeRef?) -> String? {
        switch value {
        case let url as URL: url.absoluteString
        case let string as String: string
        default: nil
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value) == .success else { return nil }
        return value
    }
}
