import Foundation
import AppKit
import ScreenCaptureKit
import Vision
import CryptoKit

/// Plain-line diagnostics, now routed through swift-log (`AppLog`) which fans
/// out to stdout + the rotating `<storage>/debug.log`. Kept as a free function
/// so every existing call site stays unchanged.
func lokalbotLog(_ message: String) {
    AppLog.line(message)
}

/// What caused a screen context capture. Raw values are stored in the
/// `screenshots.capture_trigger` column and shown to search/chat consumers.
enum ScreenCaptureTrigger: String {
    /// User switched to a different application (sampler boundary).
    case appSwitch = "app_switch"
    /// Window/tab/title changed inside the same application.
    case windowChange = "window_change"
    /// Idle fallback: nothing captured for the configured interval.
    case interval
    /// Explicit "Capture now" from the menu bar.
    case manual
}

/// Pure rate-limiting policy for event-driven capture (borrowed from
/// Screenpipe's debounce + idle-fallback split). Event triggers respect a
/// short cooldown so cmd-tabbing through apps can't spam OCR; the interval
/// trigger only fires once the user-configured idle window has passed with
/// no other capture; manual always wins.
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
        case .appSwitch, .windowChange:
            return now.timeIntervalSince(last) >= eventCooldown
        case .interval:
            return now.timeIntervalSince(last) >= idleInterval
        }
    }

    mutating func noteCheck(at now: Date = Date()) { lastCheck = now }
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
            guard isExcluded(appName: window.appName, excludedApps: excludedApps),
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
    enum Outcome: Sendable {
        case unchanged
        case stored(contentHash: Data, ocrText: String)
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

        let heic = try dependencies.heicData(preparedImage)
        let ocrText = dependencies.recognizeText(request.image)
        let sealedBox = try AES.GCM.seal(heic, using: request.key)
        guard let sealed = sealedBox.combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        try dependencies.write(sealed, request.fileURL)
        lastContentHash = contentHash
        return .stored(contentHash: contentHash, ocrText: ocrText)
    }

    /// A file write is not a completed capture until its SQLite rows commit.
    /// Let an identical screen retry when that later persistence step fails.
    func discardStored(contentHash: Data) {
        if lastContentHash == contentHash {
            lastContentHash = nil
        }
    }
}

/// Pure image transforms used by the background worker. Keeping these outside
/// the `@MainActor` service is what makes Vision, Core Graphics, and ImageIO run
/// away from SwiftUI's executor.
private enum ScreenshotImageProcessing {
    /// Hash the downscaled pixels before HEIC/OCR. Unchanged frames therefore
    /// skip both the encoder and Vision instead of paying an encode merely to
    /// discover that the output bytes match the previous capture.
    static func contentHash(of image: CGImage) -> Data {
        var input = Data()
        var width = UInt64(image.width).littleEndian
        var height = UInt64(image.height).littleEndian
        withUnsafeBytes(of: &width) { input.append(contentsOf: $0) }
        withUnsafeBytes(of: &height) { input.append(contentsOf: $0) }
        if let pixels = image.dataProvider?.data {
            input.append(pixels as Data)
        }
        return Data(SHA256.hash(data: input))
    }

    static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate   // .fast is useless on dense UI text
        request.usesLanguageCorrection = false  // code/URLs shouldn't be "corrected"
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    static func downscale(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard image.width > maxWidth else { return image }
        let scale = Double(maxWidth) / Double(image.width)
        let height = Int(Double(image.height) * scale)
        guard let context = CGContext(
            data: nil, width: maxWidth, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: height))
        return context.makeImage() ?? image
    }

    static func heicData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.heic" as CFString, 1, nil) else {
            throw NSError(domain: "LokalBot", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "HEIC encoder unavailable"])
        }
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

/// M5 (design doc §3.2/§3.4), now event-driven: capture the active display
/// when the sampler sees an app/window switch (idle timer as fallback) →
/// dedup identical frames → OCR (Vision, on-device) → AES-GCM encrypt → disk.
/// The OCR text is what's indexed and searchable; pixels and (by default)
/// text are retention-pruned. Skips idle, lock screen, pauses, and excluded apps.
@MainActor
final class ScreenshotService: ObservableObject {

    @Published private(set) var lastCapture: Date?
    @Published private(set) var lastError: String?

    private let store: ActivityStore
    private let storage: StorageManager
    private let settings: () -> AppSettings
    private let isMeetingRecordingActive: () -> Bool
    private let sampler: ActivitySampler
    private let windowTitleLookup: FocusedWindowTitleLookup
    private let processingWorker = ScreenshotProcessingWorker()
    private var timer: Timer?
    private var policy = ScreenCapturePolicy()
    private var captureGate = ScreenshotCaptureGate()

    init(store: ActivityStore, storage: StorageManager, sampler: ActivitySampler,
         windowTitleLookup: FocusedWindowTitleLookup = .shared,
         isMeetingRecordingActive: @escaping () -> Bool = { false },
         settings: @escaping () -> AppSettings) {
        self.store = store
        self.storage = storage
        self.sampler = sampler
        self.windowTitleLookup = windowTitleLookup
        self.isMeetingRecordingActive = isMeetingRecordingActive
        self.settings = settings
    }

    func start() {
        guard timer == nil else { return }
        // Event-driven path: the sampler already detects app/window boundaries
        // every 5 s; captures ride those events instead of a fixed clock.
        sampler.onActivityBoundary = { [weak self] _, _, appChanged in
            Task { @MainActor in
                await self?.captureIfAppropriate(trigger: appChanged ? .appSwitch : .windowChange)
            }
        }
        // Idle fallback: a 60 s tick that only captures when nothing has been
        // captured for the configured interval (the old slider semantics
        // become "at least every N minutes").
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.captureIfAppropriate(trigger: .interval) }
        }
        // First capture shortly after launch, not a full interval later.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            await self?.captureIfAppropriate(trigger: .interval)
        }
        pruneOldScreenshots()
    }

    func stop() {
        sampler.onActivityBoundary = nil
        timer?.invalidate()
        timer = nil
    }

    func restart() {
        stop()
        if settings().screenshotsEnabled && settings().trackingEnabled { start() }
    }

    private func captureIfAppropriate(trigger: ScreenCaptureTrigger) async {
        let config = settings()
        guard config.screenshotsEnabled, config.trackingEnabled else {
            lokalbotLog("shot skip: disabled"); return
        }
        guard !sampler.isPaused else { lokalbotLog("shot skip: paused"); return }
        guard Self.shouldCaptureDuringMeetingRecording(
            trigger: trigger,
            recordingActive: isMeetingRecordingActive())
        else {
            lokalbotLog("shot skip: recording active (\(trigger.rawValue))")
            return
        }
        guard policy.shouldCapture(trigger: trigger,
                                   idleInterval: max(60, config.screenshotIntervalMinutes * 60))
        else {
            if trigger != .interval { lokalbotLog("shot skip: cooldown (\(trigger.rawValue))") }
            return
        }
        // Never let a background trigger raise a TCC dialog: preflight is
        // prompt-free. Prompting belongs to onboarding / explicit clicks only.
        guard CGPreflightScreenCaptureAccess() else {
            lokalbotLog("shot skip: screen recording not granted"); return
        }
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 180 else { lokalbotLog("shot skip: idle \(Int(idle))s"); return }
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let frontmost = frontmostApp.localizedName,
              frontmost != "loginwindow" else { lokalbotLog("shot skip: lock screen"); return }
        guard !ScreenshotCaptureLayout.isExcluded(
            appName: frontmost, excludedApps: config.excludedAppList)
        else { lokalbotLog("shot skip: excluded (\(frontmost))"); return }

        guard captureGate.begin() else {
            lokalbotLog("shot skip: capture already in flight (\(trigger.rawValue))")
            return
        }
        defer { captureGate.end() }

        let initialTitle = await windowTitleLookup.title(
            for: frontmostApp.processIdentifier)
        guard !initialTitle.timedOut,
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == frontmostApp.processIdentifier else {
            lokalbotLog("shot skip: focused-window lookup timed out or focus changed")
            return
        }
        do {
            try await capture(frontApp: frontmost,
                              frontmostProcessID: frontmostApp.processIdentifier,
                              windowTitle: initialTitle.title ?? "",
                              excludedApps: config.excludedAppList,
                              trigger: trigger)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            lokalbotLog("shot FAILED: \(error)")
        }
    }

    private func capture(frontApp: String, frontmostProcessID: pid_t, windowTitle: String,
                         excludedApps: [String],
                         trigger: ScreenCaptureTrigger) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostProcessID else {
            lokalbotLog("shot skip: focus changed while preparing capture")
            return
        }
        let layout = ScreenshotCaptureLayout.selection(
            displays: content.displays.map {
                .init(id: $0.displayID, frame: CGDisplayBounds($0.displayID))
            },
            windows: content.windows.compactMap { window in
                guard let application = window.owningApplication else { return nil }
                return .init(
                    id: window.windowID,
                    processID: application.processID,
                    appName: application.applicationName,
                    title: window.title ?? "",
                    frame: window.frame)
            },
            frontmostProcessID: frontmostProcessID,
            focusedWindowTitle: windowTitle,
            excludedApps: excludedApps)
        guard let layout,
              let display = content.displays.first(where: { $0.displayID == layout.displayID })
        else { return }
        let excludedWindows = content.windows.filter {
            layout.excludedWindowIDs.contains($0.windowID)
        }

        // Capture at NATIVE pixel resolution — OCR needs full-size glyphs.
        // The stored image is downscaled afterwards; the text is the value.
        let configuration = SCStreamConfiguration()
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        configuration.width = mode?.pixelWidth ?? display.width * 2
        configuration.height = mode?.pixelHeight ?? display.height * 2
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)
        let currentTitle = await windowTitleLookup.title(for: frontmostProcessID)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostProcessID,
              ScreenshotWindowFocusValidation.matches(
                expectedTitle: windowTitle,
                current: currentTitle) else {
            // ScreenCaptureKit requests suspend. Do not persist a display image
            // under stale app/window metadata if the user switches meanwhile.
            lokalbotLog("shot skip: focus changed during capture")
            return
        }

        let timestamp = Date()

        // The worker keeps the hash → dedup → OCR → encryption → atomic-write
        // sequence serial and off the main actor. The check still arms the
        // cooldown/idle clock when an unchanged frame is skipped.
        let file = Self.captureFileURL(rootURL: storage.rootURL, timestamp: timestamp)
        let outcome = try await processingWorker.process(ScreenshotProcessingRequest(
            image: image,
            trigger: trigger,
            key: try Self.encryptionKey(),
            fileURL: file))

        guard case .stored(let contentHash, let ocrText) = outcome else {
            policy.noteCheck(at: timestamp)
            lokalbotLog("shot skip: unchanged frame (\(trigger.rawValue), app: \(frontApp))")
            return
        }

        do {
            try store.insertScreenshot(ts: timestamp, path: file.path, app: frontApp,
                                       windowTitle: windowTitle, trigger: trigger.rawValue,
                                       ocr: ocrText)
        } catch {
            do {
                try FileManager.default.removeItem(at: file)
            } catch let cleanupError {
                lokalbotLog("shot rollback file cleanup failed: \(cleanupError.localizedDescription)")
            }
            await processingWorker.discardStored(contentHash: contentHash)
            throw error
        }
        policy.noteCheck(at: timestamp)
        lastCapture = timestamp
        lokalbotLog("shot ok: \(file.lastPathComponent) (\(ocrText.count) OCR chars, "
            + "app: \(frontApp), trigger: \(trigger.rawValue))")
    }

    /// Manual trigger (menu bar) — the one non-onboarding place allowed to
    /// prompt, because the user explicitly asked for a capture.
    func captureNow() {
        Task { @MainActor in
            if !CGPreflightScreenCaptureAccess() {
                lokalbotLog("capture now: requesting screen recording access")
                guard CGRequestScreenCaptureAccess() else { return }
            }
            await captureIfAppropriate(trigger: .manual)
        }
    }

    /// Decrypt a stored screenshot to its raw image bytes. `nonisolated` and
    /// pure given the key, so callers can run the file read + AES open off the
    /// main actor; the key is read on the caller's actor (cheap, cached) and
    /// passed in. `Data` is `Sendable`, so the result crosses actors cleanly —
    /// the (non-`Sendable`) `NSImage` is built on the consuming actor.
    nonisolated static func decryptedData(path: String, key: SymmetricKey) -> Data? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    /// Files older than the retention window are deleted. OCR text follows
    /// the same cutoff unless the user explicitly opted into keeping it —
    /// screen text can be as sensitive as the pixels it came from.
    func pruneOldScreenshots() {
        let cutoff = Date().addingTimeInterval(-Double(settings().retentionDays) * 86_400)
        for path in store.screenshotPaths(olderThan: cutoff) {
            do {
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
                try store.clearScreenshotPath(path)
            } catch {
                // Keep the database path when deletion fails, so a later
                // retention pass can retry instead of orphaning the file.
                lokalbotLog("shot retention failed path=\(path): \(error.localizedDescription)")
            }
        }
        if !settings().keepOCRTextForever {
            _ = store.clearOCRText(olderThan: cutoff)
        }
    }

    // MARK: - Pieces

    nonisolated static func shouldCaptureDuringMeetingRecording(
        trigger: ScreenCaptureTrigger,
        recordingActive: Bool
    ) -> Bool {
        !recordingActive || trigger == .manual
    }

    nonisolated static func captureFileURL(
        rootURL: URL,
        timestamp: Date,
        identifier: UUID = UUID()
    ) -> URL {
        let day = timestamp.formatted(.iso8601.year().month().day())
        let milliseconds = Int64((timestamp.timeIntervalSince1970 * 1_000).rounded(.down))
        return rootURL
            .appendingPathComponent("activity/\(day)/shots", isDirectory: true)
            .appendingPathComponent(
                "\(milliseconds)-\(identifier.uuidString.lowercased()).heic.enc")
    }

    /// Per-install AES-256 key in the user Keychain (design §3.4), via the
    /// shared scheme also used to seal chat history.
    static func encryptionKey() throws -> SymmetricKey {
        try KeychainSecrets.symmetricKey(account: "screenshot-key")
    }
}
