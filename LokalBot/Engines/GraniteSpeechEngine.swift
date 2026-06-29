import Foundation
import FluidAudio

/// IBM Granite Speech 4.1 2B through the bundled llama.cpp server. The model is
/// local-only: first use downloads the GGUF model and multimodal projector from
/// Hugging Face, then LokalBot talks to llama-server's OpenAI-compatible audio
/// transcription endpoint on localhost.
actor GraniteSpeechEngine: TranscriptionEngine {
    static let shared = GraniteSpeechEngine()

    nonisolated let displayName = "Granite Speech 4.1 2B"
    nonisolated let supportsStreaming = false

    private static let repo = "ibm-granite/granite-speech-4.1-2b-GGUF"
    nonisolated static let modelFileName = "granite-speech-4.1-2b-Q4_K_M.gguf"
    nonisolated static let projectorFileName = "mmproj-model-f16.gguf"
    private static let prompt = "transcribe the speech with proper punctuation and capitalization."
    private static let sampleRate = 16_000
    private static let maxSegmentSeconds = 30.0
    private static let serverPort = 17_875

    private var server: LlamaServer?
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.stop() }

    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        report(.init(fractionCompleted: nil, status: "Checking..."), to: progress)
        let paths = try await preparedPaths(progress: progress)
        report(.init(fractionCompleted: nil, status: "Starting local server..."), to: progress)
        try await server(for: paths).ensureRunning(modelAt: paths.model)
        report(.init(fractionCompleted: 1, status: "Ready"), to: progress)
    }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        try await prepare()
        let started = Date()
        let regions = try await audioRegions(for: url)
        let work = try Self.makeWorkDir()
        defer { try? FileManager.default.removeItem(at: work) }

        var segments: [Transcript.Segment] = []
        for (index, region) in regions.enumerated() {
            let wav = work.appendingPathComponent("\(index).wav")
            try OnnxTranscriptionEngine.writeWav(region.samples, to: wav)
            let text = try await transcribeWav(wav)
            let normalized = Transcript.normalizedText(text)
            guard !normalized.isEmpty else { continue }
            segments.append(.init(
                start: region.start,
                end: region.end,
                speaker: "speaker",
                text: normalized,
                confidence: nil))
        }

        let elapsed = Date().timeIntervalSince(started)
        let duration = regions.last?.end ?? 0
        lokalbotLog(
            "granite-asr profile regions=\(regions.count) elapsed=\(String(format: "%.2fs", elapsed)) rtfx=\(String(format: "%.1fx", elapsed > 0 ? duration / elapsed : 0))")
        await idle.bump()
        return Transcript(segments: segments, engine: "\(Self.repo):\(Self.modelFileName) (llama.cpp)")
    }

    private func server(for paths: PreparedPaths) -> LlamaServer {
        if let server { return server }
        let instance = LlamaServer(
            port: Self.serverPort,
            contextTokens: 4_096,
            extraArgs: ["--mmproj", paths.projector.path])
        server = instance
        return instance
    }

    private func stop() async {
        await server?.stop()
        server = nil
    }

    private nonisolated func report(_ update: ModelPreparationUpdate,
                                    to handler: ModelPreparationProgressHandler?) {
        guard let handler else { return }
        Task { @MainActor in handler(update) }
    }

    // MARK: - Download / paths

    struct PreparedPaths: Sendable {
        let model: URL
        let projector: URL
    }

    private nonisolated static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppIdentifiers.bundleID, isDirectory: true)
    }

    nonisolated static func modelRoot() -> URL {
        modelRoot(appSupport: appSupport)
    }

    nonisolated static func modelRoot(appSupport: URL) -> URL {
        appSupport
            .appendingPathComponent("granite-speech", isDirectory: true)
            .appendingPathComponent("4.1-2b", isDirectory: true)
    }

    nonisolated static func modelURL() -> URL {
        modelURL(appSupport: appSupport)
    }

    nonisolated static func modelURL(appSupport: URL) -> URL {
        modelRoot(appSupport: appSupport).appendingPathComponent(modelFileName)
    }

    nonisolated static func projectorURL() -> URL {
        projectorURL(appSupport: appSupport)
    }

    nonisolated static func projectorURL(appSupport: URL) -> URL {
        modelRoot(appSupport: appSupport).appendingPathComponent(projectorFileName)
    }

    private nonisolated func preparedPaths(progress: ModelPreparationProgressHandler?) async throws -> PreparedPaths {
        let root = Self.modelRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let model = Self.modelURL()
        try await Self.downloadIfNeeded(
            fileName: Self.modelFileName,
            destination: model,
            status: "Downloading Granite model...",
            progress: progress)

        let projector = Self.projectorURL()
        try await Self.downloadIfNeeded(
            fileName: Self.projectorFileName,
            destination: projector,
            status: "Downloading Granite projector...",
            progress: progress)

        guard ModelFileValidator.looksLikeGGUF(model),
              ModelFileValidator.looksLikeGGUF(projector) else {
            throw EngineError.modelUnavailable
        }
        return .init(model: model, projector: projector)
    }

    private nonisolated static func downloadIfNeeded(
        fileName: String,
        destination: URL,
        status: String,
        progress: ModelPreparationProgressHandler?
    ) async throws {
        if ModelFileValidator.looksLikeGGUF(destination) { return }
        try? FileManager.default.removeItem(at: destination)
        report(.init(fractionCompleted: nil, status: status), to: progress)

        let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)")!
        let (downloaded, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw EngineError.downloadFailed
        }

        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(fileName).\(UUID().uuidString).partial")
        try FileManager.default.moveItem(at: downloaded, to: staged)
        guard ModelFileValidator.looksLikeGGUF(staged) else {
            try? FileManager.default.removeItem(at: staged)
            throw EngineError.modelUnavailable
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staged, to: destination)
    }

    private nonisolated static func report(_ update: ModelPreparationUpdate,
                                           to handler: ModelPreparationProgressHandler?) {
        guard let handler else { return }
        Task { @MainActor in handler(update) }
    }

    // MARK: - Audio segmentation

    private struct AudioRegion: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let samples: [Float]
    }

    private nonisolated func audioRegions(for url: URL) async throws -> [AudioRegion] {
        if let analysis = await SpeechActivity.shared.speechRegions(in: url),
           !analysis.segments.isEmpty {
            var regions: [AudioRegion] = []
            for segment in analysis.segments {
                let start = max(0, segment.startSample(sampleRate: Self.sampleRate))
                let end = min(analysis.samples.count, segment.endSample(sampleRate: Self.sampleRate))
                guard end > start else { continue }
                regions.append(contentsOf: Self.split(
                    samples: analysis.samples,
                    start: start,
                    end: end,
                    baseTime: 0))
            }
            if !regions.isEmpty { return regions }
        }

        let samples = try AudioConverter().resampleAudioFile(url)
        return Self.split(samples: samples, start: 0, end: samples.count, baseTime: 0)
    }

    private nonisolated static func split(samples: [Float], start: Int, end: Int,
                                          baseTime: TimeInterval) -> [AudioRegion] {
        guard end > start else { return [] }
        let maxSamples = max(1, Int(maxSegmentSeconds * Double(sampleRate)))
        var regions: [AudioRegion] = []
        var cursor = start
        while cursor < end {
            let next = min(cursor + maxSamples, end)
            regions.append(.init(
                start: baseTime + Double(cursor) / Double(sampleRate),
                end: baseTime + Double(next) / Double(sampleRate),
                samples: Array(samples[cursor..<next])))
            cursor = next
        }
        return regions
    }

    private nonisolated static func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-asr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - llama-server request

    private func transcribeWav(_ wav: URL) async throws -> String {
        guard let server else { throw EngineError.serverUnavailable }
        let boundary = "lokalbot-\(UUID().uuidString)"
        var request = URLRequest(url: server.baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.multipartBody(
            boundary: boundary,
            fields: [
                "model": Self.modelFileName,
                "prompt": Self.prompt,
            ],
            fileURL: wav)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EngineError.transcriptionFailed("no response") }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(decoding: data.prefix(512), as: UTF8.self)
            throw EngineError.transcriptionFailed("HTTP \(http.statusCode): \(message)")
        }
        guard let payload = try? JSONDecoder().decode(TranscriptionResponse.self, from: data),
              let text = payload.text else {
            throw EngineError.transcriptionFailed("invalid response")
        }
        return text
    }

    private nonisolated static func multipartBody(boundary: String,
                                                  fields: [String: String],
                                                  fileURL: URL) throws -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private struct TranscriptionResponse: Decodable {
        let text: String?
    }

    enum EngineError: LocalizedError {
        case downloadFailed
        case modelUnavailable
        case serverUnavailable
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed:
                "Granite Speech could not be downloaded from Hugging Face."
            case .modelUnavailable:
                "Granite Speech files are missing or invalid."
            case .serverUnavailable:
                "Granite Speech local server is not running."
            case .transcriptionFailed(let detail):
                "Granite Speech transcription failed: \(detail)"
            }
        }
    }
}
