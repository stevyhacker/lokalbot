import CoreImage
import Foundation
import ScreenCaptureKit
import Vision

/// A single latest-frame slot. Pixels never leave this object or reach storage.
final class MeetingSpeakerFrameSource: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        var buffer: CVPixelBuffer
        var hostTime: Double
    }
    private let lock = NSLock()
    private var latest: Frame?
    private var activeStreamID: ObjectIdentifier?
    private var stream: SCStream?
    private var windowID: CGWindowID?
    private let queue = DispatchQueue(label: "lokalbot.meeting-speaker.frames", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])

    @MainActor func start(window: SCWindow) async throws {
        if windowID == window.windowID { return }
        await stop()
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.queueDepth = 3
        let scale = min(2, 2_048 / max(1, window.frame.width), sqrt(2_097_152 / max(1, window.frame.width * window.frame.height)))
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        let created = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
        try created.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        windowID = window.windowID
        stream = created
        activate(created)
        do { try await created.startCapture() } catch { await stop(); throw error }
    }

    @MainActor func stop() async {
        let old = stream
        stream = nil
        windowID = nil
        activate(nil)
        try? await old?.stopCapture()
        clear()
    }
    private func clear() { lock.lock(); latest = nil; lock.unlock() }
    private func activate(_ stream: SCStream?) {
        lock.lock()
        activeStreamID = stream.map(ObjectIdentifier.init)
        latest = nil
        lock.unlock()
    }
    func frame() -> Frame? { lock.lock(); defer { lock.unlock() }; return latest }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let metadata = attachments.first,
              let status = metadata[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let ticks = metadata[.displayTime] as? UInt64,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frame = Frame(buffer: pixels, hostTime: RecordingAudioClock.hostSeconds(ticks))
        lock.lock()
        if activeStreamID == ObjectIdentifier(stream) { latest = frame }
        lock.unlock()
    }

    /// Runs off the main actor. Restrict recognition to the known tile's name
    /// strip; require a matching readable name AND the active border/equalizer.
    func activeTile(_ tile: MeetingParticipantTile, in frame: Frame, window: CGRect, verifyName: Bool) -> Bool {
        let image = CIImage(cvPixelBuffer: frame.buffer)
        let scaleX = image.extent.width / window.width
        let scaleY = image.extent.height / window.height
        let local = CGRect(x: (tile.frame.minX - window.minX) * scaleX,
            y: image.extent.height - (tile.frame.maxY - window.minY) * scaleY,
            width: tile.frame.width * scaleX, height: tile.frame.height * scaleY).integral
        guard image.extent.contains(local), local.width >= 80, local.height >= 60,
              let crop = context.createCGImage(image, from: local) else { return false }
        if verifyName {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 0.30)
            guard (try? VNImageRequestHandler(cgImage: crop).perform([request])) != nil,
                  request.results?.contains(where: {
                      guard let text = $0.topCandidates(1).first, text.confidence >= 0.85 else { return false }
                      return ParticipantObservation.nameKey(text.string) == ParticipantObservation.nameKey(tile.name)
                  }) == true else { return false }
        }
        return Self.hasActiveBorderAndEqualizer(crop)
    }

    static func hasActiveBorderAndEqualizer(_ image: CGImage) -> Bool {
        // Shape + border jointly: a pinned blue tile, presenter highlight, or
        // arbitrary blue image alone is insufficient. Unsupported themes abstain.
        let width = 160, height = 100
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return false }
        func blue(_ x: Int, _ y: Int) -> Bool {
            let offset = (y * width + x) * 4
            return pixels[offset + 2] > 150 && Int(pixels[offset + 2]) - Int(pixels[offset]) > 55 && pixels[offset + 1] > 85
        }
        let horizontal = (8..<(width - 8)).filter { blue($0, 1) || blue($0, 2) }.count
        let vertical = (8..<(height - 8)).filter { blue(1, $0) || blue(2, $0) }.count
        guard horizontal > 100, vertical > 55 else { return false }
        // Three separated narrow columns with a taller middle bar in a corner.
        for originX in [8, width - 28] {
            for originY in [8, height - 28] {
                let columns = (0..<20).map { x in (0..<20).filter { y in blue(originX + x, originY + y) }.count }
                var runs: [[Int]] = []
                for (index, count) in columns.enumerated() where count >= 3 && count <= 15 {
                    if let last = runs.last?.last, index == last + 1 { runs[runs.count - 1].append(index) } else { runs.append([index]) }
                }
                if runs.count == 3, runs.allSatisfy({ (1...4).contains($0.count) }),
                   let middle = runs[1].map({ columns[$0] }).max(),
                   middle >= 7, middle > (runs[0].map { columns[$0] }.max() ?? 0),
                   middle > (runs[2].map { columns[$0] }.max() ?? 0) { return true }
            }
        }
        return false
    }
}
