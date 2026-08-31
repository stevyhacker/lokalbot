import AppKit
import CryptoKit
import Foundation
import ImageIO
import ScreenCaptureKit

enum ScreenCaptureTrigger: String {
    /// User switched to a different application (sampler boundary).
    case appSwitch = "app_switch"
    /// Window/tab/title changed inside the same application.
    case windowChange = "window_change"
    /// A click completed; coordinates and button identity are never retained.
    case click
    /// Typing stopped briefly; no key code or typed string is observed here.
    case typingPause = "typing_pause"
    /// Scrolling settled; deltas and pointer position are not retained.
    case scrollSettled = "scroll_settled"
    /// The pasteboard generation changed; clipboard contents are never read.
    case clipboardChange = "clipboard_change"
    /// Idle fallback: nothing captured for the configured interval.
    case interval
    /// Explicit "Capture now" from the menu bar.
    case manual
}

/// A fully decoded, size-bounded image that can safely cross back from the
/// detached thumbnail worker. CGImage is immutable, but older SDK annotations
/// do not consistently mark it Sendable.
struct ScreenThumbnailImage: @unchecked Sendable {
    let image: CGImage

    var byteCost: Int {
        max(1, image.bytesPerRow * image.height)
    }
}

/// Pure rate-limiting policy for event-driven capture. Event triggers respect
/// a short cooldown so interaction bursts cannot spam extraction; the interval
/// trigger fires only after the user-configured idle window; manual always wins.
struct ScreenCapturePolicy {
    /// Minimum seconds between event-driven captures.
    var eventCooldown: TimeInterval
    /// When a capture (or dedup-confirmed unchanged screen) was last recorded.
    private(set) var lastCheck: Date?

    init(eventCooldown: TimeInterval = 20) {
        self.eventCooldown = eventCooldown
    }

    func shouldCapture(trigger: ScreenCaptureTrigger, idleInterval: TimeInterval,
                       now: Date = Date()) -> Bool {
        guard let last = lastCheck else { return true }
        switch trigger {
        case .manual:
            return true
        case .appSwitch, .windowChange, .click, .typingPause, .scrollSettled,
             .clipboardChange:
            return now.timeIntervalSince(last) >= eventCooldown
        case .interval:
            return now.timeIntervalSince(last) >= idleInterval
        }
    }

    mutating func noteCheck(at now: Date = Date()) { lastCheck = now }
}

/// Bounds retention work to once per day during normal operation while still
/// allowing explicit privacy changes to force an immediate pass. Keeping this
/// policy pure makes sleep/wake and clock-adjustment behavior deterministic in
/// tests; the service owns only the lightweight timer that asks it periodically.
struct ScreenshotRetentionSchedule {
    static let pruneInterval: TimeInterval = 86_400

    private(set) var lastPrune: Date?

    mutating func shouldPrune(at now: Date, force: Bool = false) -> Bool {
        if !force, let lastPrune {
            let elapsed = now.timeIntervalSince(lastPrune)
            guard elapsed < 0 || elapsed >= Self.pruneInterval else { return false }
        }
        lastPrune = now
        return true
    }

    static func requiresImmediatePrune(previousDays: Int, currentDays: Int) -> Bool {
        currentDays < previousDays
    }
}

/// Pure capture-layout selection. ScreenCaptureKit objects cannot be created
/// in unit tests, so production metadata is reduced to these value types before
/// choosing the focused display and every privacy-excluded window on it.
struct ScreenshotCaptureLayout {
    struct Display {
        let id: CGDirectDisplayID
        let frame: CGRect
    }

    struct Window {
        let id: CGWindowID
        let processID: pid_t
        let appName: String
        let title: String
        let frame: CGRect
    }

    struct Selection: Equatable {
        let displayID: CGDirectDisplayID
        let excludedWindowIDs: Set<CGWindowID>
    }

    static func selection(
        displays: [Display],
        windows: [Window],
        frontmostProcessID: pid_t,
        focusedWindowTitle: String,
        excludedApps: [String],
        excludePrivateWindows: Bool = true,
        mainDisplayID: CGDirectDisplayID = CGMainDisplayID()
    ) -> Selection? {
        guard !displays.isEmpty else { return nil }

        let frontmostWindows = windows.filter {
            $0.processID == frontmostProcessID && !$0.frame.isEmpty && !$0.frame.isNull
        }
        let focusedWindow: Window?
        if focusedWindowTitle.isEmpty {
            focusedWindow = frontmostWindows.first
        } else {
            focusedWindow = frontmostWindows.first {
                $0.title.compare(focusedWindowTitle, options: [.caseInsensitive, .diacriticInsensitive])
                    == .orderedSame
            } ?? frontmostWindows.first
        }

        let selectedDisplay: Display
        if let focusedWindow,
           let overlappingDisplay = displays.max(by: {
               intersectionArea($0.frame, focusedWindow.frame)
                   < intersectionArea($1.frame, focusedWindow.frame)
           }), intersectionArea(overlappingDisplay.frame, focusedWindow.frame) > 0 {
            selectedDisplay = overlappingDisplay
        } else {
            selectedDisplay = displays.first(where: { $0.id == mainDisplayID }) ?? displays[0]
        }

        let excludedWindowIDs = Set(windows.compactMap { window -> CGWindowID? in
            let excludedForApp = isExcluded(
                appName: window.appName, excludedApps: excludedApps)
            let excludedForPrivacy = excludePrivateWindows
                && ScreenContextPrivacy.isPrivateWindow(title: window.title)
            guard excludedForApp || excludedForPrivacy,
                  intersectionArea(window.frame, selectedDisplay.frame) > 0 else { return nil }
            return window.id
        })
        return Selection(displayID: selectedDisplay.id, excludedWindowIDs: excludedWindowIDs)
    }

    static func isExcluded(appName: String, excludedApps: [String]) -> Bool {
        excludedApps.contains { rawTerm in
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            return !term.isEmpty && appName.localizedCaseInsensitiveContains(term)
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}

/// ScreenCaptureKit allocates the requested frame before the background worker
/// can downsample it. Bound that first allocation so large/retina displays do
/// not briefly consume hundreds of megabytes on every context event.
struct ScreenshotCaptureDimensions: Equatable {
    static let maximumDimension = 1_500

    let width: Int
    let height: Int

    static func bounded(
        pixelWidth: Int,
        pixelHeight: Int,
        maximumDimension: Int = maximumDimension
    ) -> ScreenshotCaptureDimensions {
        let sourceWidth = max(1, pixelWidth)
        let sourceHeight = max(1, pixelHeight)
        let limit = max(1, maximumDimension)
        let longest = max(sourceWidth, sourceHeight)
        guard longest > limit else {
            return ScreenshotCaptureDimensions(width: sourceWidth, height: sourceHeight)
        }
        let scale = Double(limit) / Double(longest)
        return ScreenshotCaptureDimensions(
            width: max(1, Int((Double(sourceWidth) * scale).rounded())),
            height: max(1, Int((Double(sourceHeight) * scale).rounded())))
    }
}

/// Main-actor gate that prevents repeated menu clicks and simultaneous sampler
/// events from launching overlapping ScreenCaptureKit requests.
struct ScreenshotCaptureGate {
    private(set) var isCapturing = false

    mutating func begin() -> Bool {
        guard !isCapturing else { return false }
        isCapturing = true
        return true
    }

    mutating func end() {
        isCapturing = false
    }
}

enum ScreenshotWindowFocusValidation {
    static func matches(
        expectedTitle: String,
        current: FocusedWindowTitleLookupResult
    ) -> Bool {
        guard !current.timedOut else { return false }
        return (current.title ?? "").compare(
            expectedTitle,
            options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

/// Immutable inputs passed across the main-actor/worker boundary. `CGImage` is
/// an immutable Core Foundation value and is safe to read concurrently, but it
/// is not annotated `Sendable` by every supported SDK, so the wrapper records
/// that invariant explicitly.
struct ScreenshotProcessingRequest: @unchecked Sendable {
    let image: CGImage
    let trigger: ScreenCaptureTrigger
    let key: SymmetricKey
    let fileURL: URL
    let accessibleText: String
    let accessibilityRedactionCount: Int

    init(
        image: CGImage,
        trigger: ScreenCaptureTrigger,
        key: SymmetricKey,
        fileURL: URL,
        accessibleText: String = "",
        accessibilityRedactionCount: Int = 0
    ) {
        self.image = image
        self.trigger = trigger
        self.key = key
        self.fileURL = fileURL
        self.accessibleText = accessibleText
        self.accessibilityRedactionCount = max(0, accessibilityRedactionCount)
    }
}

/// Injectable image/file operations keep the serial worker deterministic under
/// test without weakening the production path. Every closure runs only inside
/// `ScreenshotProcessingWorker`.
struct ScreenshotProcessingDependencies: @unchecked Sendable {
    let contentHash: @Sendable (CGImage) -> Data
    let heicData: @Sendable (CGImage) throws -> Data
    let recognizeText: @Sendable (CGImage) -> String
    let write: @Sendable (Data, URL) throws -> Void

    static let live = ScreenshotProcessingDependencies(
        contentHash: { image in ScreenshotImageProcessing.contentHash(of: image) },
        heicData: { image in try ScreenshotImageProcessing.heicData(from: image) },
        recognizeText: { image in ScreenshotImageProcessing.recognizeText(in: image) },
        write: { data, url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        })
}

/// CPU- and I/O-heavy screenshot processing. Actor isolation gives captures one
/// total order, so the content hash always compares with the last image that was
/// successfully encrypted and written. There are no suspension points inside
/// `process`, preventing actor reentrancy from interleaving two capture writes.
actor ScreenshotProcessingWorker {
    struct StoredCapture: Sendable {
        let contentHash: Data
        let text: String
        let textSource: String
        let hasPixels: Bool
        let privacyRedactionCount: Int
        let usedOCR: Bool
    }

    enum Outcome: Sendable {
        case unchanged
        case stored(StoredCapture)
    }

    private let dependencies: ScreenshotProcessingDependencies
    private var lastContentHash: Data?

    init(dependencies: ScreenshotProcessingDependencies = .live) {
        self.dependencies = dependencies
    }

    func process(_ request: ScreenshotProcessingRequest) throws -> Outcome {
        let preparedImage = ScreenshotImageProcessing.downscale(request.image, maxWidth: 1500)
        let contentHash = dependencies.contentHash(preparedImage)
        if request.trigger != .manual, contentHash == lastContentHash {
            return .unchanged
        }

        let accessible = ScreenContextPrivacy.redact(request.accessibleText)
        let accessibilityRedactions = request.accessibilityRedactionCount + accessible.count
        let hasRichAccessibility = ScreenContextPrivacy.hasRichAccessibleText(accessible.text)
        let ocr = hasRichAccessibility
            ? ScreenContextPrivacy.Redaction(text: "", count: 0)
            : ScreenContextPrivacy.redact(dependencies.recognizeText(preparedImage))

        let text: String
        let textSource: String
        if hasRichAccessibility {
            text = accessible.text
            textSource = accessibilityRedactions > 0
                ? "accessibility_redacted" : "accessibility"
        } else if !accessible.text.isEmpty, !ocr.text.isEmpty {
            text = String((accessible.text + "\n" + ocr.text).prefix(36_000))
            textSource = (accessibilityRedactions + ocr.count) > 0 ? "hybrid_redacted" : "hybrid"
        } else if !accessible.text.isEmpty {
            text = accessible.text
            textSource = accessibilityRedactions > 0
                ? "accessibility_redacted" : "accessibility"
        } else {
            text = ocr.text
            textSource = ocr.count > 0 ? "ocr_redacted" : "ocr"
        }

        let redactionCount = accessibilityRedactions + ocr.count
        // If extracted text reveals a credential, retain only its deterministic
        // redacted form. Dropping the entire pixel payload is safer than trying
        // to infer a precise on-screen rectangle from a text-only observation.
        let hasPixels = redactionCount == 0
        if hasPixels {
            let heic = try dependencies.heicData(preparedImage)
            let sealedBox = try AES.GCM.seal(heic, using: request.key)
            guard let sealed = sealedBox.combined else {
                throw CocoaError(.fileWriteUnknown)
            }
            try dependencies.write(sealed, request.fileURL)
        }
        lastContentHash = contentHash
        return .stored(StoredCapture(
            contentHash: contentHash,
            text: text,
            textSource: textSource,
            hasPixels: hasPixels,
            privacyRedactionCount: redactionCount,
            usedOCR: !hasRichAccessibility))
    }

    /// A file write is not a completed capture until its SQLite rows commit.
    /// Let an identical screen retry when that later persistence step fails.
    func discardStored(contentHash: Data) {
        if lastContentHash == contentHash {
            lastContentHash = nil
        }
    }
}

/// 64-bit difference hash (dHash) for visually similar-frame detection.
/// Unlike a byte SHA, this remains stable across tiny cursor/animation/codec
/// changes. Automatic captures within `defaultDistanceThreshold` are skipped;
/// explicit manual captures always bypass that decision in the worker above.
enum ScreenPerceptualHash {
    static let width = 9
    static let height = 8
    static let defaultDistanceThreshold = 6

    static func hash(of image: CGImage) -> UInt64 {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return 0 }

        var result: UInt64 = 0
        var bit: UInt64 = 1
        for row in 0..<height {
            let offset = row * width
            for column in 0..<(width - 1) {
                if pixels[offset + column] > pixels[offset + column + 1] {
                    result |= bit
                }
                bit <<= 1
            }
        }
        return result
    }

    static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    static func isNearDuplicate(
        _ lhs: UInt64,
        _ rhs: UInt64,
        threshold: Int = defaultDistanceThreshold
    ) -> Bool {
        hammingDistance(lhs, rhs) <= max(0, threshold)
    }

}

/// Pure image transforms used by the background worker. Keeping these outside
/// the `@MainActor` service is what makes Vision, Core Graphics, and ImageIO run
/// away from SwiftUI's executor.
