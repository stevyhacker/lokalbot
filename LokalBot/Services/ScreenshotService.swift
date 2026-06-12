import Foundation
import AppKit
import ScreenCaptureKit
import Vision
import CryptoKit

/// Plain-file diagnostics (<storage>/debug.log) — NSLog/os_log proved
/// unreliable to read back for debug builds.
func lokalbotLog(_ message: String) {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent(AppIdentifiers.bundleID)
        .appendingPathComponent("debug.log")
    let line = "\(Date().formatted(.iso8601)) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

/// M5 (design doc §3.2/§3.4): periodic screenshot of the active display →
/// downscale → OCR (Vision, on-device) → AES-GCM encrypt → disk.
/// The OCR text is what's indexed and searchable; the pixels are
/// retention-pruned. Skips idle, lock screen, pauses, and excluded apps.
@MainActor
final class ScreenshotService: ObservableObject {

    @Published private(set) var lastCapture: Date?
    @Published private(set) var lastError: String?

    private let store: ActivityStore
    private let storage: StorageManager
    private let settings: () -> AppSettings
    private let sampler: ActivitySampler
    private var timer: Timer?

    init(store: ActivityStore, storage: StorageManager, sampler: ActivitySampler,
         settings: @escaping () -> AppSettings) {
        self.store = store
        self.storage = storage
        self.sampler = sampler
        self.settings = settings
    }

    func start() {
        guard timer == nil else { return }
        let interval = max(60, settings().screenshotIntervalMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.captureIfAppropriate() }
        }
        // First capture shortly after launch, not a full interval later.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            await self?.captureIfAppropriate()
        }
        pruneOldScreenshots()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func restart() {
        stop()
        if settings().screenshotsEnabled && settings().trackingEnabled { start() }
    }

    private func captureIfAppropriate() async {
        let config = settings()
        guard config.screenshotsEnabled, config.trackingEnabled else {
            lokalbotLog("shot skip: disabled"); return
        }
        guard !sampler.isPaused else { lokalbotLog("shot skip: paused"); return }
        // Never let the background timer trigger a TCC dialog: preflight is
        // prompt-free. Prompting belongs to onboarding / explicit clicks only.
        guard CGPreflightScreenCaptureAccess() else {
            lokalbotLog("shot skip: screen recording not granted"); return
        }
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 180 else { lokalbotLog("shot skip: idle \(Int(idle))s"); return }
        guard let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName,
              frontmost != "loginwindow" else { lokalbotLog("shot skip: lock screen"); return }
        guard !config.excludedAppList.contains(where: { frontmost.localizedCaseInsensitiveContains($0) })
        else { lokalbotLog("shot skip: excluded (\(frontmost))"); return }

        do {
            try await capture(frontApp: frontmost)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            lokalbotLog("shot FAILED: \(error)")
        }
    }

    private func capture(frontApp: String) async throws {
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
        let ocrText = Self.recognizeText(in: image)

        // Downscale → HEIC → encrypt → activity/YYYY-MM-DD/shots/<epoch>.heic.enc
        let heic = try Self.heicData(from: Self.downscale(image, maxWidth: 1500))
        let sealed = try AES.GCM.seal(heic, using: Self.encryptionKey()).combined!
        let day = timestamp.formatted(.iso8601.year().month().day())
        let folder = storage.rootURL.appendingPathComponent("activity/\(day)/shots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(Int(timestamp.timeIntervalSince1970)).heic.enc")
        try sealed.write(to: file, options: .atomic)

        store.insertScreenshot(ts: timestamp, path: file.path, app: frontApp, ocr: ocrText)
        lastCapture = timestamp
        lokalbotLog("shot ok: \(file.lastPathComponent) (\(ocrText.count) OCR chars, app: \(frontApp))")
    }

    /// Manual trigger (menu bar) — the one non-onboarding place allowed to
    /// prompt, because the user explicitly asked for a capture.
    func captureNow() {
        Task { @MainActor in
            if !CGPreflightScreenCaptureAccess() {
                lokalbotLog("capture now: requesting screen recording access")
                guard CGRequestScreenCaptureAccess() else { return }
            }
            await captureIfAppropriate()
        }
    }

    /// Decrypt a stored screenshot for viewing.
    static func decrypt(path: String) -> NSImage? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: try encryptionKey()) else { return nil }
        return NSImage(data: plain)
    }

    /// Files older than the retention window are deleted; OCR text is kept
    /// (it is the searchable value and it's small).
    func pruneOldScreenshots() {
        let cutoff = Date().addingTimeInterval(-Double(settings().retentionDays) * 86_400)
        for path in store.screenshotPaths(olderThan: cutoff) {
            try? FileManager.default.removeItem(atPath: path)
        }
        store.clearScreenshotPaths(olderThan: cutoff)
    }

    // MARK: - Pieces

    private static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate   // .fast is useless on dense UI text
        request.usesLanguageCorrection = false  // code/URLs shouldn't be "corrected"
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private static func downscale(_ image: CGImage, maxWidth: Int) -> CGImage {
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

    private static func heicData(from image: CGImage) throws -> Data {
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

    /// Per-install AES-256 key in the user Keychain (design §3.4).
    private static var cachedKey: SymmetricKey?
    static func encryptionKey() throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        if let data = KeychainSecrets.data(account: "screenshot-key") {
            let key = SymmetricKey(data: data)
            cachedKey = key
            return key
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        KeychainSecrets.set(data, account: "screenshot-key")
        guard KeychainSecrets.data(account: "screenshot-key") != nil else {
            throw NSError(domain: "LokalBot", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Could not save screenshot encryption key"])
        }
        cachedKey = key
        return key
    }
}
