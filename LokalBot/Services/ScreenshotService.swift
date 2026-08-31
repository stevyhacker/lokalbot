import Foundation
import AppKit
import ImageIO
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
enum ScreenshotImageProcessing {
    /// Hash the downscaled pixels before HEIC/OCR. Only byte-identical frames
    /// are suppressed; the much coarser perceptual hash is persisted later for
    /// visual grouping and must never discard changed OCR evidence.
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
        let dimensions = ScreenshotCaptureDimensions.bounded(
            pixelWidth: image.width,
            pixelHeight: image.height,
            maximumDimension: maxWidth)
        guard dimensions.width != image.width || dimensions.height != image.height else {
            return image
        }
        guard let context = CGContext(
            data: nil, width: dimensions.width, height: dimensions.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: 0, y: 0, width: dimensions.width, height: dimensions.height))
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

/// Event-driven screen context: read bounded visible Accessibility text first,
/// optionally pair it with an encrypted active-display image, and invoke local
/// OCR only when the accessible text is thin. Captured text is indexed; pixels
/// and, by default, text are retention-pruned. Privacy checks fail closed for
/// idle/lock states, excluded sources, secure fields, and detected credentials.
@MainActor
final class ScreenshotService: ObservableObject {

    @Published private(set) var lastCapture: Date?
    @Published private(set) var lastVisualCapture: Date?
    @Published private(set) var lastAccessibilityCapture: Date?
    @Published private(set) var lastOCRCapture: Date?
    @Published private(set) var lastTextSource: String?
    @Published private(set) var lastRetentionRun: Date?
    @Published private(set) var lastRetentionError: String?
    @Published private(set) var isCapturing = false
    @Published private(set) var lastError: String?

    private let store: ActivityStore
    private let storage: StorageManager
    private let settings: () -> AppSettings
    private let isMeetingRecordingActive: () -> Bool
    private let activeMeetingID: () -> UUID?
    private let isHighPriorityInteractionActive: () -> Bool
    private let now: () -> Date
    private let sampler: ActivitySampler
    private let windowTitleLookup: FocusedWindowTitleLookup
    private let accessibilityReader: ScreenAccessibilityReader
    private let processingWorker = ScreenshotProcessingWorker()
    private let eventMonitor = ScreenContextEventMonitor()
    private var timer: Timer?
    private var retentionTimer: Timer?
    private var initialCaptureTask: Task<Void, Never>?
    private var captureGeneration = 0
    private var policy = ScreenCapturePolicy()
    private var retentionSchedule = ScreenshotRetentionSchedule()
    private var captureGate = ScreenshotCaptureGate()
    private var lastTextFingerprint: Data?
    private var lastMeetingCapture: Date?

    init(store: ActivityStore, storage: StorageManager, sampler: ActivitySampler,
         windowTitleLookup: FocusedWindowTitleLookup = .shared,
         accessibilityReader: ScreenAccessibilityReader = .shared,
         isMeetingRecordingActive: @escaping () -> Bool = { false },
         activeMeetingID: @escaping () -> UUID? = { nil },
         isHighPriorityInteractionActive: @escaping () -> Bool = { false },
         now: @escaping () -> Date = Date.init,
         settings: @escaping () -> AppSettings) {
        self.store = store
        self.storage = storage
        self.sampler = sampler
        self.windowTitleLookup = windowTitleLookup
        self.accessibilityReader = accessibilityReader
        self.isMeetingRecordingActive = isMeetingRecordingActive
        self.activeMeetingID = activeMeetingID
        self.isHighPriorityInteractionActive = isHighPriorityInteractionActive
        self.now = now
        self.settings = settings
    }

    func start() {
        startRetentionMaintenance()
        guard timer == nil else { return }
        captureGeneration &+= 1
        let generation = captureGeneration
        // Event-driven path: the sampler already detects app/window boundaries
        // every 5 s; captures ride those events instead of a fixed clock.
        sampler.onActivityBoundary = { [weak self] _, _, appChanged in
            Task { @MainActor in
                await self?.captureIfAppropriate(trigger: appChanged ? .appSwitch : .windowChange)
            }
        }
        eventMonitor.onTrigger = { [weak self] trigger in
            Task { @MainActor in await self?.captureIfAppropriate(trigger: trigger) }
        }
        eventMonitor.start()
        // Idle fallback: a 60 s tick that only captures when nothing has been
        // captured for the configured interval (the old slider semantics
        // become "at least every N minutes").
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.captureIfAppropriate(trigger: .interval) }
        }
        // First capture shortly after launch, not a full interval later.
        initialCaptureTask?.cancel()
        initialCaptureTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
            guard let self, self.captureGeneration == generation else { return }
            await self.captureIfAppropriate(trigger: .interval)
            if self.captureGeneration == generation { self.initialCaptureTask = nil }
        }
    }

    func stop() {
        captureGeneration &+= 1
        initialCaptureTask?.cancel()
        initialCaptureTask = nil
        sampler.onActivityBoundary = nil
        eventMonitor.stop()
        timer?.invalidate()
        timer = nil
        retentionTimer?.invalidate()
        retentionTimer = nil
    }

    func restart() {
        stop()
        // Retention is a privacy lifecycle, not a capture lifecycle. Keep its
        // daily maintenance alive even when tracking/capture is disabled.
        startRetentionMaintenance()
        if settings().effectiveScreenContextCaptureMode.capturesText,
           settings().trackingEnabled { start() }
    }

    private func startRetentionMaintenance() {
        _ = runRetentionMaintenanceIfNeeded()
        guard retentionTimer == nil else { return }
        let maintenance = Timer.scheduledTimer(
            withTimeInterval: 60 * 60,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                _ = self?.runRetentionMaintenanceIfNeeded()
            }
        }
        maintenance.tolerance = 5 * 60
        retentionTimer = maintenance
    }

    private func captureIfAppropriate(trigger: ScreenCaptureTrigger) async {
        let config = settings()
        let mode = config.effectiveScreenContextCaptureMode
        guard let request = captureRequest(trigger: trigger, config: config, mode: mode) else {
            return
        }
        let recordingActive = request.recordingActive
        let current = request.timestamp
        let frontmostApp = request.application
        let frontmost = request.applicationName

        guard captureGate.begin() else {
            lokalbotLog("context skip: capture already in flight (\(trigger.rawValue))")
            return
        }
        isCapturing = true
        defer {
            captureGate.end()
            isCapturing = false
        }

        let initialTitle = await windowTitleLookup.title(
            for: frontmostApp.processIdentifier)
        guard !initialTitle.timedOut,
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == frontmostApp.processIdentifier else {
            lokalbotLog("context skip: focused-window lookup timed out or focus changed")
            return
        }
        let windowTitle = initialTitle.title ?? ""
        if !config.capturePrivateWindows,
           ScreenContextPrivacy.isPrivateWindow(title: windowTitle) {
            policy.noteCheck(at: current)
            lokalbotLog("context skip: private browsing window")
            return
        }

        let accessibility = await accessibilityReader.capture(
            processID: frontmostApp.processIdentifier)
        if !accessibility.timedOut { lastAccessibilityCapture = current }
        if accessibility.snapshot?.focusedSecureField == true {
            policy.noteCheck(at: current)
            lokalbotLog("context skip: focused secure field")
            return
        }
        let sourceURL = accessibility.snapshot?.sourceURL
        if ScreenContextPrivacy.isExcluded(
            sourceURL: sourceURL,
            rules: config.excludedScreenDomainList) {
            policy.noteCheck(at: current)
            lokalbotLog("context skip: excluded domain")
            return
        }
        let redactedAccessibility = ScreenContextPrivacy.redact(
            accessibility.snapshot?.text ?? "")
        let redactedWindowTitle = ScreenContextPrivacy.redact(windowTitle)
        let redactedSourceURL = ScreenContextPrivacy.redact(sourceURL ?? "")
        let redactedDocumentName = ScreenContextPrivacy.redact(
            accessibility.snapshot?.documentName ?? "")
        let preCaptureRedactions = redactedAccessibility.count
            + redactedWindowTitle.count
            + redactedSourceURL.count
            + redactedDocumentName.count
        let meetingID = recordingActive ? activeMeetingID()?.uuidString : nil
        let previousCapture = lastCapture
        let screenCaptureGranted = mode.capturesPixels && CGPreflightScreenCaptureAccess()

        do {
            if !mode.capturesPixels || preCaptureRedactions > 0
                || !screenCaptureGranted {
                try storeTextContext(
                    text: redactedAccessibility.text,
                    redactionCount: preCaptureRedactions,
                    sourceURL: redactedSourceURL.text,
                    documentName: redactedDocumentName.text,
                    frontApp: frontmost,
                    windowTitle: redactedWindowTitle.text,
                    trigger: trigger,
                    meetingID: meetingID,
                    timestamp: current)
                if mode.capturesPixels, !screenCaptureGranted {
                    lokalbotLog("context visual fallback: screen recording not granted")
                }
            } else {
                try await capture(
                    frontApp: frontmost,
                    frontmostProcessID: frontmostApp.processIdentifier,
                    windowTitle: windowTitle,
                    storedWindowTitle: redactedWindowTitle.text,
                    excludedApps: config.excludedAppList,
                    excludePrivateWindows: !config.capturePrivateWindows,
                    trigger: trigger,
                    accessibleText: redactedAccessibility.text,
                    accessibilityRedactionCount: preCaptureRedactions,
                    sourceURL: redactedSourceURL.text,
                    documentName: redactedDocumentName.text,
                    meetingID: meetingID)
            }
            if recordingActive, lastCapture != previousCapture { lastMeetingCapture = current }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            lokalbotLog("context FAILED: \(error)")
        }
    }

    private struct CaptureRequest {
        let recordingActive: Bool
        let timestamp: Date
        let application: NSRunningApplication
        let applicationName: String
    }

    private func captureRequest(
        trigger: ScreenCaptureTrigger,
        config: AppSettings,
        mode: AppSettings.ScreenContextCaptureMode
    ) -> CaptureRequest? {
        guard mode.capturesText, config.trackingEnabled else {
            lokalbotLog("context skip: disabled"); return nil
        }
        guard !sampler.isPaused else { lokalbotLog("context skip: paused"); return nil }
        if trigger != .manual, isHighPriorityInteractionActive() {
            lokalbotLog("context skip: interactive capture has priority")
            return nil
        }
        let recordingActive = isMeetingRecordingActive()
        guard Self.shouldCaptureDuringMeetingRecording(
            trigger: trigger,
            recordingActive: recordingActive,
            visualContextEnabled: config.meetingVisualContextEnabled && mode.capturesPixels)
        else {
            lokalbotLog("context skip: recording active (\(trigger.rawValue))")
            return nil
        }
        guard policy.shouldCapture(trigger: trigger,
                                   idleInterval: max(60, config.screenshotIntervalMinutes * 60))
        else {
            if trigger != .interval { lokalbotLog("context skip: cooldown (\(trigger.rawValue))") }
            return nil
        }
        let current = now()
        if recordingActive, trigger != .manual,
           let lastMeetingCapture,
           current.timeIntervalSince(lastMeetingCapture) < 60 {
            lokalbotLog("context skip: meeting capture cooldown")
            return nil
        }
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 180 else { lokalbotLog("context skip: idle \(Int(idle))s"); return nil }
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let frontmost = frontmostApp.localizedName,
              frontmost != "loginwindow" else {
            lokalbotLog("context skip: lock screen"); return nil
        }
        guard !Self.shouldSkipAutomaticSelfCapture(
            trigger: trigger,
            frontmostProcessID: frontmostApp.processIdentifier,
            ownProcessID: ProcessInfo.processInfo.processIdentifier
        ) else {
            lokalbotLog("context skip: LokalBot frontmost")
            return nil
        }
        guard !ScreenshotCaptureLayout.isExcluded(
            appName: frontmost, excludedApps: config.excludedAppList)
        else { lokalbotLog("context skip: excluded app (\(frontmost))"); return nil }
        return .init(
            recordingActive: recordingActive,
            timestamp: current,
            application: frontmostApp,
            applicationName: frontmost)
    }

    private func storeTextContext(
        text: String,
        redactionCount: Int,
        sourceURL: String?,
        documentName: String?,
        frontApp: String,
        windowTitle: String,
        trigger: ScreenCaptureTrigger,
        meetingID: String?,
        timestamp: Date
    ) throws {
        let clipped = String(text.prefix(36_000))
        guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            policy.noteCheck(at: timestamp)
            lokalbotLog("context skip: no accessible text")
            return
        }
        let fingerprint = Data(SHA256.hash(data: Data(
            "\(frontApp)\u{1f}\(windowTitle)\u{1f}\(clipped)".utf8)))
        if trigger != .manual, fingerprint == lastTextFingerprint {
            policy.noteCheck(at: timestamp)
            lokalbotLog("context skip: unchanged accessible text")
            return
        }
        let source = redactionCount > 0 ? "accessibility_redacted" : "accessibility"
        try store.insertScreenshot(
            ts: timestamp,
            path: "",
            app: frontApp,
            windowTitle: windowTitle,
            trigger: trigger.rawValue,
            textSource: source,
            ocr: clipped,
            sourceURL: sourceURL ?? "",
            documentName: documentName ?? "",
            meetingID: meetingID ?? "",
            privacyRedactions: redactionCount)
        lastTextFingerprint = fingerprint
        policy.noteCheck(at: timestamp)
        lastCapture = timestamp
        lastTextSource = source
        lokalbotLog("context ok: text-only (\(clipped.count) chars, app: \(frontApp), trigger: \(trigger.rawValue))")
    }

    private func capture(frontApp: String, frontmostProcessID: pid_t, windowTitle: String,
                         storedWindowTitle: String,
                         excludedApps: [String],
                         excludePrivateWindows: Bool,
                         trigger: ScreenCaptureTrigger,
                         accessibleText: String,
                         accessibilityRedactionCount: Int,
                         sourceURL: String?,
                         documentName: String?,
                         meetingID: String?) async throws {
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
            excludedApps: excludedApps,
            excludePrivateWindows: excludePrivateWindows)
        guard let layout,
              let display = content.displays.first(where: { $0.displayID == layout.displayID })
        else { return }
        let excludedWindows = content.windows.filter {
            layout.excludedWindowIDs.contains($0.windowID)
        }

        // Bound the source frame before ScreenCaptureKit allocates it. Vision
        // receives this same readable 1,500 px frame in the worker; requesting
        // a native 5K/6K IOSurface only inflated transient memory.
        let configuration = SCStreamConfiguration()
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let dimensions = ScreenshotCaptureDimensions.bounded(
            pixelWidth: mode?.pixelWidth ?? display.width * 2,
            pixelHeight: mode?.pixelHeight ?? display.height * 2)
        configuration.width = dimensions.width
        configuration.height = dimensions.height
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

        // The worker keeps hash → text-source selection → optional OCR →
        // redaction → encryption/write serial and off the main actor.
        let file = Self.captureFileURL(rootURL: storage.rootURL, timestamp: timestamp)
        let outcome = try await processingWorker.process(ScreenshotProcessingRequest(
            image: image,
            trigger: trigger,
            key: try Self.encryptionKey(),
            fileURL: file,
            accessibleText: accessibleText,
            accessibilityRedactionCount: accessibilityRedactionCount))

        guard case .stored(let stored) = outcome else {
            policy.noteCheck(at: timestamp)
            lokalbotLog("context skip: unchanged frame (\(trigger.rawValue), app: \(frontApp))")
            return
        }

        let storedPath = stored.hasPixels ? file.path : ""
        do {
            try store.insertScreenshot(
                ts: timestamp,
                path: storedPath,
                app: frontApp,
                windowTitle: storedWindowTitle,
                trigger: trigger.rawValue,
                textSource: stored.textSource,
                ocr: stored.text,
                perceptualHash: ScreenPerceptualHash.hash(of: image),
                sourceURL: sourceURL ?? "",
                documentName: documentName ?? "",
                meetingID: meetingID ?? "",
                privacyRedactions: stored.privacyRedactionCount)
        } catch {
            if FileManager.default.fileExists(atPath: file.path) {
                do {
                    try FileManager.default.removeItem(at: file)
                } catch let cleanupError {
                    lokalbotLog("context rollback file cleanup failed: \(cleanupError.localizedDescription)")
                }
            }
            await processingWorker.discardStored(contentHash: stored.contentHash)
            throw error
        }
        policy.noteCheck(at: timestamp)
        lastCapture = timestamp
        lastTextSource = stored.textSource
        if stored.hasPixels { lastVisualCapture = timestamp }
        if stored.usedOCR { lastOCRCapture = timestamp }
        let payload = stored.hasPixels ? file.lastPathComponent : "text-only after redaction"
        lokalbotLog("context ok: \(payload) (\(stored.text.count) text chars, source: "
            + "\(stored.textSource), app: \(frontApp), trigger: \(trigger.rawValue))")
    }

    /// Manual trigger (menu bar) — the one non-onboarding place allowed to
    /// prompt, because the user explicitly asked for a capture.
    func captureNow() {
        Task { @MainActor in
            if settings().effectiveScreenContextCaptureMode.capturesPixels,
               !CGPreflightScreenCaptureAccess() {
                lokalbotLog("capture now: requesting screen recording access")
                _ = CGRequestScreenCaptureAccess()
            }
            await captureIfAppropriate(trigger: .manual)
        }
    }

    /// Decrypt a stored screenshot to raw image bytes. `nonisolated` and pure
    /// given the key, so the thumbnail worker can run file I/O and AES opening
    /// off the main actor before immediately downsampling the result.
    nonisolated static func decryptedData(path: String, key: SymmetricKey) -> Data? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    /// Decode only the pixels needed by the destination view. The immediate
    /// cache option forces HEIF/PNG decoding to finish on the detached worker
    /// instead of being deferred until SwiftUI draws on the main actor.
    nonisolated static func downsampledThumbnail(
        data: Data,
        maxPixelSize: Int
    ) -> ScreenThumbnailImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        // ImageIO requires a heterogeneous CFDictionary at this boundary.
        let options: [CFString: Any] = [ // swiftlint:disable:this no_dynamic_any
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        return ScreenThumbnailImage(image: image)
    }

    nonisolated static func decryptedThumbnail(
        path: String,
        key: SymmetricKey,
        maxPixelSize: Int
    ) -> ScreenThumbnailImage? {
        guard let data = decryptedData(path: path, key: key) else { return nil }
        return downsampledThumbnail(data: data, maxPixelSize: maxPixelSize)
    }

    /// Callers that already hold screenshot metadata avoid another synchronous
    /// SQLite lookup. File I/O, AES opening, and image decoding all stay off the
    /// main actor and only the bounded CGImage returns to SwiftUI.
    func decryptedThumbnail(
        for screenshot: ActivityStore.Screenshot,
        maxPixelSize: Int
    ) async -> ScreenThumbnailImage? {
        guard screenshot.hasPixels else { return nil }
        let path = screenshot.path
#if LOKALBOT_UI_TEST_HOST
        if ProcessInfo.processInfo.environment["LOKALBOT_SCREEN_MEMORY_DEMO"] == "1" {
            return await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                    return nil
                }
                return Self.downsampledThumbnail(data: data, maxPixelSize: maxPixelSize)
            }.value
        }
#endif
        guard let key = try? Self.encryptionKey() else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self.decryptedThumbnail(
                path: path,
                key: key,
                maxPixelSize: maxPixelSize)
        }.value
    }

    /// User-requested deletion removes pixels first, then the screenshot row
    /// and all linked OCR, bookmark, and semantic-vector state atomically.
    func deleteCapture(id: Int64) throws {
        guard let screenshot = store.screenshot(id: id) else { return }
        if !screenshot.path.isEmpty,
           FileManager.default.fileExists(atPath: screenshot.path) {
            try FileManager.default.removeItem(atPath: screenshot.path)
        }
        try store.deleteScreenshot(id: id)
    }

    @discardableResult
    func deleteCaptures(in interval: DateInterval) throws -> Int {
        guard interval.end > interval.start else { return 0 }
        let captures = store.screenshots(
            in: interval, app: nil, bookmarkedOnly: false,
            includingMissingFiles: true)
        for capture in captures {
            if !capture.path.isEmpty,
               FileManager.default.fileExists(atPath: capture.path) {
                try FileManager.default.removeItem(atPath: capture.path)
            }
        }
        try store.deleteScreenshots(ids: captures.map(\.id))
        return captures.count
    }

    /// Files older than the retention window are deleted. OCR text follows
    /// the same cutoff unless the user explicitly opted into keeping it —
    /// screen text can be as sensitive as the pixels it came from.
    func pruneOldScreenshots() {
        _ = runRetentionMaintenanceIfNeeded(force: true)
    }

    /// Called by the hourly maintenance timer. The schedule guarantees the
    /// actual filesystem/SQLite pass runs at most daily unless a retention
    /// reduction or explicit privacy action forces it.
    @discardableResult
    func runRetentionMaintenanceIfNeeded(force: Bool = false) -> Bool {
        let current = now()
        guard retentionSchedule.shouldPrune(at: current, force: force) else { return false }
        performRetentionPrune(at: current)
        return true
    }

    private func performRetentionPrune(at current: Date) {
        let cutoff = current.addingTimeInterval(-Double(settings().retentionDays) * 86_400)
        var firstError: String?
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
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        if !settings().keepOCRTextForever {
            if !store.clearOCRText(olderThan: cutoff), firstError == nil {
                firstError = "Could not prune expired screen text."
            }
        }
        lastRetentionRun = current
        lastRetentionError = firstError
    }

    // MARK: - Pieces

    nonisolated static func shouldCaptureDuringMeetingRecording(
        trigger: ScreenCaptureTrigger,
        recordingActive: Bool,
        visualContextEnabled: Bool = false
    ) -> Bool {
        !recordingActive || trigger == .manual || visualContextEnabled
    }

    nonisolated static func shouldSkipAutomaticSelfCapture(
        trigger: ScreenCaptureTrigger,
        frontmostProcessID: pid_t,
        ownProcessID: pid_t
    ) -> Bool {
        trigger != .manual && frontmostProcessID == ownProcessID
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
