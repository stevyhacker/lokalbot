import CryptoKit
import Foundation

/// Downloads large static files through parallel HTTP byte ranges, falling
/// back to a single streamed GET when the server can't do ranges (or the file
/// is small enough that ranges don't pay off).
///
/// Hugging Face's CDN supports `Accept-Ranges: bytes` for the GGUF files in the
/// model catalog. A single `URLSessionDownloadTask` can sit well below the
/// user's available bandwidth on fast links, while a small number of ranged
/// requests usually keeps the pipe busier. Callers still validate the final
/// bytes before installing the model. Either way the caller gets one temp-file
/// URL back with progress reported throughout — there is exactly one download
/// path to reason about.
///
/// Ranged downloads are resumable: the partially assembled file and a small
/// manifest of completed parts live at a stable per-URL path, so a failed,
/// cancelled, or app-quit download picks up where it stopped instead of
/// re-fetching 17 GB from byte zero. Pass `stashDirectory` to keep that state
/// somewhere durable (the temp default can be reaped by macOS between runs).
enum ParallelRangeDownloader {

    /// Completed-part bookkeeping persisted next to the partial file. The
    /// stored URL/size/partSize must match the current request exactly or the
    /// stash is discarded — a changed upstream file must never be stitched
    /// together from two different versions.
    struct ResumeState: Codable, Equatable {
        let url: String
        let totalBytes: Int64
        let partSize: Int64
        var completedParts: [Int]
    }
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

    private enum FallbackRequired: Error {
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

    /// Downloads `url` to a temp file, ranged when the server supports it and
    /// the file is large enough, else via one streamed GET. Returns the temp
    /// URL; the caller validates and installs it.
    static func download(
        from url: URL,
        session: URLSession,
        partSize: Int64 = defaultPartSize,
        maxConcurrentParts: Int = defaultMaxConcurrentParts,
        stashDirectory: URL? = nil,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        do {
            return try await downloadRanged(
                from: url, session: session, partSize: partSize,
                maxConcurrentParts: maxConcurrentParts,
                stashDirectory: stashDirectory, progress: progress)
        } catch is FallbackRequired {
            return try await downloadWhole(from: url, session: session, progress: progress)
        }
    }

    /// Stable per-URL name for resume state, so a retried download finds its
    /// earlier partial file no matter how it was initiated.
    static func stashName(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func downloadRanged(
        from url: URL,
        session: URLSession,
        partSize: Int64,
        maxConcurrentParts: Int,
        stashDirectory: URL?,
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
        let stashDir = stashDirectory ?? fileManager.temporaryDirectory
        let stash = stashName(for: url)
        let assembled = stashDir.appendingPathComponent("LokalBot-resume-\(stash).partial")
        let manifestURL = stashDir.appendingPathComponent("LokalBot-resume-\(stash).json")
        try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stashDir, withIntermediateDirectories: true)

        // On success the assembled file is handed to the caller and the
        // manifest deleted; on any failure (including cancellation) both stay
        // behind so the next attempt resumes instead of starting over.
        defer { try? fileManager.removeItem(at: workDir) }

        let byteRanges = ranges(totalBytes: probe.totalBytes, partSize: partSize)
        guard !byteRanges.isEmpty else { throw DownloadError.invalidContentLength }

        var completed: Set<Int> = []
        if let data = try? Data(contentsOf: manifestURL),
           let state = try? JSONDecoder().decode(ResumeState.self, from: data),
           state.url == url.absoluteString,
           state.totalBytes == probe.totalBytes,
           state.partSize == partSize,
           fileManager.fileExists(atPath: assembled.path) {
            completed = Set(state.completedParts).intersection(byteRanges.map(\.index))
        } else {
            try? fileManager.removeItem(at: assembled)
            try? fileManager.removeItem(at: manifestURL)
        }
        if !fileManager.fileExists(atPath: assembled.path) {
            _ = fileManager.createFile(atPath: assembled.path, contents: nil)
        }
        let output = try FileHandle(forWritingTo: assembled)
        defer { try? output.close() }

        var state = ResumeState(url: url.absoluteString, totalBytes: probe.totalBytes,
                                partSize: partSize, completedParts: completed.sorted())
        try await downloadParts(
            byteRanges,
            skipping: completed,
            url: url,
            workDir: workDir,
            session: session,
            output: output,
            totalBytes: probe.totalBytes,
            maxConcurrentParts: max(1, maxConcurrentParts),
            progress: progress,
            partCompleted: { index in
                state.completedParts.append(index)
                if let data = try? JSONEncoder().encode(state) {
                    try? data.write(to: manifestURL, options: .atomic)
                }
            })

        let actual = fileSize(assembled)
        guard actual == probe.totalBytes else {
            // Corrupt stash (e.g. the partial file was truncated behind our
            // back) — throw it away so the next attempt starts clean.
            try? fileManager.removeItem(at: assembled)
            try? fileManager.removeItem(at: manifestURL)
            throw DownloadError.assemblySizeMismatch(expected: probe.totalBytes, actual: actual)
        }

        try? fileManager.removeItem(at: manifestURL)
        progress(.init(bytesWritten: probe.totalBytes, totalBytes: probe.totalBytes))
        return assembled
    }

    /// Single streamed GET for servers without byte-range support (or files
    /// below the acceleration threshold). Still reports progress — unlike a
    /// bare `URLSession.download(from:)` — so a 1.5 GB fallback download never
    /// looks frozen in the UI.
    private static func downloadWhole(
        from url: URL,
        session: URLSession,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(AppIdentifiers.bundleID, forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DownloadError.httpStatus(http.statusCode)
        }
        let totalBytes = parseContentLength(http)

        let fileManager = FileManager.default
        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("LokalBot-download-\(UUID().uuidString)", isDirectory: false)
        _ = fileManager.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)

        var success = false
        defer {
            try? output.close()
            if !success { try? fileManager.removeItem(at: destination) }
        }

        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(8 * 1024 * 1024)
        progress(.init(bytesWritten: 0, totalBytes: totalBytes))
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 8 * 1024 * 1024 {
                try output.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(.init(bytesWritten: written, totalBytes: totalBytes))
            }
        }
        if !buffer.isEmpty {
            try output.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        progress(.init(bytesWritten: written, totalBytes: max(totalBytes, written)))
        success = true
        return destination
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
        skipping alreadyCompleted: Set<Int> = [],
        url: URL,
        workDir: URL,
        session: URLSession,
        output: FileHandle,
        totalBytes: Int64,
        maxConcurrentParts: Int,
        progress: @escaping @Sendable (Progress) -> Void,
        partCompleted: (Int) -> Void = { _ in }
    ) async throws {
        let remaining = byteRanges.filter { !alreadyCompleted.contains($0.index) }
        try await withThrowingTaskGroup(of: PartResult.self) { group in
            var iterator = remaining.makeIterator()
            var active = 0
            var completedBytes: Int64 = byteRanges
                .filter { alreadyCompleted.contains($0.index) }
                .reduce(0) { $0 + $1.length }
            var completedParts = alreadyCompleted.count
            progress(.init(bytesWritten: completedBytes, totalBytes: totalBytes))

            func addNextPart() {
                guard let range = iterator.next() else { return }
                active += 1
                group.addTask {
                    try await downloadPart(range, from: url, into: workDir, session: session)
                }
            }

            for _ in 0..<min(maxConcurrentParts, remaining.count) {
                addNextPart()
            }

            while active > 0 {
                guard let part = try await group.next() else { break }
                active -= 1
                defer { try? FileManager.default.removeItem(at: part.url) }
                try copyFile(part.url, to: output, atOffset: part.range.start)
                completedBytes += part.range.length
                completedParts += 1
                partCompleted(part.range.index)
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
