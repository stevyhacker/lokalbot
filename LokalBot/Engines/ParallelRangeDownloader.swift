import Foundation

/// Downloads large static files through parallel HTTP byte ranges.
///
/// Hugging Face's CDN supports `Accept-Ranges: bytes` for the GGUF files in the
/// model catalog. A single `URLSessionDownloadTask` can sit well below the
/// user's available bandwidth on fast links, while a small number of ranged
/// requests usually keeps the pipe busier. Callers still validate the final
/// bytes before installing the model.
enum ParallelRangeDownloader {
    struct Progress: Sendable {
        let bytesWritten: Int64
        let totalBytes: Int64

        var fractionCompleted: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, max(0, Double(bytesWritten) / Double(totalBytes)))
        }
    }

    struct ByteRange: Equatable, Sendable {
        let index: Int
        let start: Int64
        let end: Int64

        var length: Int64 { end - start + 1 }
    }

    enum FallbackRequired: Error {
        case unsupported
    }

    enum DownloadError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case invalidContentLength
        case unexpectedRangeStatus(Int)
        case wrongPartSize(expected: Int64, actual: Int64)
        case assemblySizeMismatch(expected: Int64, actual: Int64)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "Download failed: invalid server response."
            case .httpStatus(let status):
                "Download failed (HTTP \(status))."
            case .invalidContentLength:
                "Download failed: server did not report a valid file size."
            case .unexpectedRangeStatus(let status):
                "Download failed: server did not honor byte ranges (HTTP \(status))."
            case .wrongPartSize(let expected, let actual):
                "Download failed: received \(actual) bytes for a \(expected)-byte chunk."
            case .assemblySizeMismatch(let expected, let actual):
                "Download failed: assembled \(actual) bytes for a \(expected)-byte model."
            }
        }
    }

    static let minimumAcceleratedSize: Int64 = 256 * 1024 * 1024
    static let defaultPartSize: Int64 = 64 * 1024 * 1024
    static let defaultMaxConcurrentParts = 6

    static func ranges(totalBytes: Int64, partSize: Int64 = defaultPartSize) -> [ByteRange] {
        guard totalBytes > 0, partSize > 0 else { return [] }
        var out: [ByteRange] = []
        var start: Int64 = 0
        var index = 0
        while start < totalBytes {
            let end = min(start + partSize - 1, totalBytes - 1)
            out.append(.init(index: index, start: start, end: end))
            start = end + 1
            index += 1
        }
        return out
    }

    static func download(
        from url: URL,
        session: URLSession,
        partSize: Int64 = defaultPartSize,
        maxConcurrentParts: Int = defaultMaxConcurrentParts,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let probe = try await probe(url: url, session: session)
        guard probe.supportsByteRanges,
              probe.totalBytes >= minimumAcceleratedSize else {
            throw FallbackRequired.unsupported
        }

        let fileManager = FileManager.default
        let workDir = fileManager.temporaryDirectory
            .appendingPathComponent("LokalBot-ranged-\(UUID().uuidString)", isDirectory: true)
        let assembled = fileManager.temporaryDirectory
            .appendingPathComponent("LokalBot-download-\(UUID().uuidString)", isDirectory: false)
        try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)

        var success = false
        defer {
            try? fileManager.removeItem(at: workDir)
            if !success {
                try? fileManager.removeItem(at: assembled)
            }
        }

        let byteRanges = ranges(totalBytes: probe.totalBytes, partSize: partSize)
        guard !byteRanges.isEmpty else { throw DownloadError.invalidContentLength }

        progress(.init(bytesWritten: 0, totalBytes: probe.totalBytes))
        _ = fileManager.createFile(atPath: assembled.path, contents: nil)
        let output = try FileHandle(forWritingTo: assembled)
        defer { try? output.close() }

        try await downloadParts(
            byteRanges,
            url: url,
            workDir: workDir,
            session: session,
            output: output,
            totalBytes: probe.totalBytes,
            maxConcurrentParts: max(1, maxConcurrentParts),
            progress: progress)

        let actual = fileSize(assembled)
        guard actual == probe.totalBytes else {
            throw DownloadError.assemblySizeMismatch(expected: probe.totalBytes, actual: actual)
        }

        success = true
        progress(.init(bytesWritten: probe.totalBytes, totalBytes: probe.totalBytes))
        return assembled
    }

    private struct Probe: Sendable {
        let totalBytes: Int64
        let supportsByteRanges: Bool
    }

    private struct PartResult: Sendable {
        let range: ByteRange
        let url: URL
    }

    private static func probe(url: URL, session: URLSession) async throws -> Probe {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(AppIdentifiers.bundleID, forHTTPHeaderField: "User-Agent")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 405 || http.statusCode == 501 {
                throw FallbackRequired.unsupported
            }
            throw DownloadError.httpStatus(http.statusCode)
        }

        let totalBytes = parseContentLength(http)
        guard totalBytes > 0 else { throw FallbackRequired.unsupported }
        let supportsByteRanges = http.value(forHTTPHeaderField: "Accept-Ranges")?
            .localizedCaseInsensitiveContains("bytes") == true
        return Probe(totalBytes: totalBytes, supportsByteRanges: supportsByteRanges)
    }

    private static func parseContentLength(_ response: HTTPURLResponse) -> Int64 {
        if response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        if let header = response.value(forHTTPHeaderField: "Content-Length"),
           let parsed = Int64(header) {
            return parsed
        }
        if let linkedSize = response.value(forHTTPHeaderField: "X-Linked-Size"),
           let parsed = Int64(linkedSize) {
            return parsed
        }
        return -1
    }

    private static func downloadParts(
        _ byteRanges: [ByteRange],
        url: URL,
        workDir: URL,
        session: URLSession,
        output: FileHandle,
        totalBytes: Int64,
        maxConcurrentParts: Int,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: PartResult.self) { group in
            var iterator = byteRanges.makeIterator()
            var active = 0
            var completedBytes: Int64 = 0
            var completedParts = 0

            func addNextPart() {
                guard let range = iterator.next() else { return }
                active += 1
                group.addTask {
                    try await downloadPart(range, from: url, into: workDir, session: session)
                }
            }

            for _ in 0..<min(maxConcurrentParts, byteRanges.count) {
                addNextPart()
            }

            while active > 0 {
                guard let part = try await group.next() else { break }
                active -= 1
                defer { try? FileManager.default.removeItem(at: part.url) }
                try copyFile(part.url, to: output, atOffset: part.range.start)
                completedBytes += part.range.length
                completedParts += 1
                progress(.init(bytesWritten: completedBytes, totalBytes: totalBytes))
                addNextPart()
            }

            guard completedParts == byteRanges.count else {
                throw DownloadError.assemblySizeMismatch(
                    expected: totalBytes,
                    actual: completedBytes)
            }
        }
    }

    private static func downloadPart(
        _ range: ByteRange,
        from url: URL,
        into workDir: URL,
        session: URLSession
    ) async throws -> PartResult {
        try Task.checkCancellation()

        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(AppIdentifiers.bundleID, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")

        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.invalidResponse
        }
        guard http.statusCode == 206 else {
            throw DownloadError.unexpectedRangeStatus(http.statusCode)
        }

        let size = fileSize(temporary)
        guard size == range.length else {
            try? FileManager.default.removeItem(at: temporary)
            throw DownloadError.wrongPartSize(expected: range.length, actual: size)
        }

        let destination = workDir.appendingPathComponent(String(format: "part-%05d", range.index))
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return .init(range: range, url: destination)
    }

    private static func copyFile(_ inputURL: URL, to output: FileHandle, atOffset offset: Int64) throws {
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }

        try output.seek(toOffset: UInt64(offset))
        while true {
            let data = try input.read(upToCount: 8 * 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
        if let number = size as? NSNumber { return number.int64Value }
        if let integer = size as? Int64 { return integer }
        if let integer = size as? Int { return Int64(integer) }
        return -1
    }
}
