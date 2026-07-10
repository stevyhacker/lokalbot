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
    private let processingWorker = ScreenshotProcessingWorker()
    private var timer: Timer?
    private var policy = ScreenCapturePolicy()

    init(store: ActivityStore, storage: StorageManager, sampler: ActivitySampler,
         isMeetingRecordingActive: @escaping () -> Bool = { false },
         settings: @escaping () -> AppSettings) {
        self.store = store
        self.storage = storage
        self.sampler = sampler
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
        guard !config.excludedAppList.contains(where: { frontmost.localizedCaseInsensitiveContains($0) })
        else { lokalbotLog("shot skip: excluded (\(frontmost))"); return }

        do {
            try await capture(frontApp: frontmost,
                              windowTitle: ActivitySampler.focusedWindowTitle(
                                  pid: frontmostApp.processIdentifier) ?? "",
                              trigger: trigger)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            lokalbotLog("shot FAILED: \(error)")
        }
    }

    private func capture(frontApp: String, windowTitle: String,
                         trigger: ScreenCaptureTrigger) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { return }

        // Capture at NATIVE pixel resolution — OCR needs full-size glyphs.
        // The stored image is downscaled afterwards; the text is the value.
        let configuration = SCStreamConfiguration()
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        configuration.width = mode?.pixelWidth ?? display.width * 2
        configuration.height = mode?.pixelHeight ?? display.height * 2
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)

        let timestamp = Date()

        // The worker keeps the hash → dedup → OCR → encryption → atomic-write
        // sequence serial and off the main actor. The check still arms the
        // cooldown/idle clock when an unchanged frame is skipped.
        let day = timestamp.formatted(.iso8601.year().month().day())
        let file = storage.rootURL
            .appendingPathComponent("activity/\(day)/shots", isDirectory: true)
            .appendingPathComponent("\(Int(timestamp.timeIntervalSince1970)).heic.enc")
        let outcome = try await processingWorker.process(ScreenshotProcessingRequest(
            image: image,
            trigger: trigger,
            key: try Self.encryptionKey(),
            fileURL: file))

        guard case .stored(_, let ocrText) = outcome else {
            policy.noteCheck(at: timestamp)
            lokalbotLog("shot skip: unchanged frame (\(trigger.rawValue), app: \(frontApp))")
            return
        }

        store.insertScreenshot(ts: timestamp, path: file.path, app: frontApp,
                               windowTitle: windowTitle, trigger: trigger.rawValue,
                               ocr: ocrText)
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
            try? FileManager.default.removeItem(atPath: path)
        }
        store.clearScreenshotPaths(olderThan: cutoff)
        if !settings().keepOCRTextForever {
            store.clearOCRText(olderThan: cutoff)
        }
    }

    // MARK: - Pieces

    nonisolated static func shouldCaptureDuringMeetingRecording(
        trigger: ScreenCaptureTrigger,
        recordingActive: Bool
    ) -> Bool {
        !recordingActive || trigger == .manual
    }

    /// Per-install AES-256 key in the user Keychain (design §3.4), via the
    /// shared scheme also used to seal chat history.
    static func encryptionKey() throws -> SymmetricKey {
        try KeychainSecrets.symmetricKey(account: "screenshot-key")
    }
}
