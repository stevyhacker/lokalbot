import Foundation
import SQLite3

/// M6 semantic layer (design §4.1): transcript/summary chunks embedded with
/// nomic-embed-text v1.5 (146 MB GGUF, auto-downloaded) served by the second
/// llama-server instance. Vectors live in SQLite; query = brute-force cosine
/// (normalized dot) — instant at personal-library scale, no extra dependency.
@MainActor
final class EmbeddingIndex {

    struct Hit: Identifiable {
        let id = UUID()
        let meetingID: UUID
        let start: TimeInterval
        let text: String
        let score: Float
    }

    private static let modelFile = "nomic-embed-text-v1.5.Q8_0.gguf"
    private static let modelURL =
        "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf"

    private var db: OpaquePointer?
    private let storage: StorageManager
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL, storage: StorageManager) {
        self.storage = storage
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { db = nil; return }
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS embeddings (
                meeting_id TEXT NOT NULL, start REAL NOT NULL,
                text TEXT NOT NULL, vec BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS embedded_meetings (
                meeting_id TEXT PRIMARY KEY, source_mtime REAL NOT NULL);
            """, nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

    // MARK: - Indexing

    func reindexAll(_ meetings: [Meeting]) async {
        for meeting in meetings {
            try? await index(meeting)
        }
    }

    func index(_ meeting: Meeting) async throws {
        let folder = meeting.folderURL(in: storage)
        let mtime = ["transcript.json", "summary.md"].compactMap {
            (try? FileManager.default.attributesOfItem(
                atPath: folder.appendingPathComponent($0).path))?[.modificationDate] as? Date
        }.map(\.timeIntervalSince1970).max() ?? 0
        guard mtime > 0, indexedMtime(meeting.id) ?? -1 < mtime else { return }

        var chunks: [(start: TimeInterval, text: String)] = []
        if let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
           let transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
            var current = ""
            var start: TimeInterval = 0
            for segment in transcript.segments {
                if current.isEmpty { start = segment.start }
                current += "\(segment.speaker.capitalized): \(segment.text)\n"
                if current.count > 500 {
                    chunks.append((start, current))
                    current = ""
                }
            }
            if !current.isEmpty { chunks.append((start, current)) }
        }
        if let summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"),
                                     encoding: .utf8) {
            for section in summary.components(separatedBy: "\n## ") where section.count > 40 {
                chunks.append((0, String(section.prefix(700))))
            }
        }
        guard !chunks.isEmpty else { return }

        let vectors = try await Self.embed(chunks.map(\.text), prefix: "search_document: ",
                                           storage: storage)
        run("DELETE FROM embeddings WHERE meeting_id = ?1", [meeting.id.uuidString])
        for (chunk, vector) in zip(chunks, vectors) {
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(db,
                "INSERT INTO embeddings (meeting_id, start, text, vec) VALUES (?1, ?2, ?3, ?4)",
                -1, &s, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(s, 1, meeting.id.uuidString, -1, Self.transient)
            sqlite3_bind_double(s, 2, chunk.start)
            sqlite3_bind_text(s, 3, String(chunk.text.prefix(300)), -1, Self.transient)
            vector.withUnsafeBufferPointer {
                sqlite3_bind_blob(s, 4, $0.baseAddress, Int32($0.count * 4), Self.transient)
            }
            sqlite3_step(s)
            sqlite3_finalize(s)
        }
        run("INSERT OR REPLACE INTO embedded_meetings (meeting_id, source_mtime) VALUES (?1, ?2)",
            [meeting.id.uuidString, mtime])
    }

    // MARK: - Query

    func search(_ query: String, limit: Int = 10) async -> [Hit] {
        guard let queryVector = try? await Self.embed([query], prefix: "search_query: ",
                                                      storage: storage).first else { return [] }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT meeting_id, start, text, vec FROM embeddings",
                                 -1, &s, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(s) }
        var hits: [Hit] = []
        while sqlite3_step(s) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(s, 0),
                  let meetingID = UUID(uuidString: String(cString: idText)),
                  let blob = sqlite3_column_blob(s, 3) else { continue }
            let count = Int(sqlite3_column_bytes(s, 3)) / 4
            guard count == queryVector.count else { continue }
            let vector = blob.withMemoryRebound(to: Float.self, capacity: count) {
                Array(UnsafeBufferPointer(start: $0, count: count))
            }
            let score = zip(queryVector, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            if score > 0.45 {
                hits.append(Hit(meetingID: meetingID,
                                start: sqlite3_column_double(s, 1),
                                text: String(cString: sqlite3_column_text(s, 2)),
                                score: score))
            }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: - Embedding via llama-server

    private static func embed(_ texts: [String], prefix: String,
                              storage: StorageManager) async throws -> [[Float]] {
        let modelPath = try await ensureModel(storage: storage)
        try await LlamaServer.embedder.ensureRunning(modelAt: modelPath)

        var request = URLRequest(url: LlamaServer.embedder.baseURL
            .appendingPathComponent("embeddings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "input": texts.map { prefix + $0 },
            "model": "nomic-embed-text-v1.5",
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else {
            throw TextEngineError.badResponse("unexpected /v1/embeddings payload")
        }
        return rows.compactMap { row -> [Float]? in
            guard let values = row["embedding"] as? [Double] else { return nil }
            let vector = values.map(Float.init)
            let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
            return norm > 0 ? vector.map { $0 / norm } : vector
        }
    }

    private static func ensureModel(storage: StorageManager) async throws -> URL {
        let folder = storage.rootURL.appendingPathComponent("models", isDirectory: true)
        let path = folder.appendingPathComponent(modelFile)
        if FileManager.default.fileExists(atPath: path.path) { return path }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (temp, response) = try await URLSession.shared.download(from: URL(string: modelURL)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TextEngineError.badResponse("embedding model download failed")
        }
        try? FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: temp, to: path)
        return path
    }

    // MARK: - Plumbing

    private func indexedMtime(_ id: UUID) -> TimeInterval? {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "SELECT source_mtime FROM embedded_meetings WHERE meeting_id = ?1",
            -1, &s, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, id.uuidString, -1, Self.transient)
        return sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_double(s, 0) : nil
    }

    private func run(_ sql: String, _ values: [Any]) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        for (index, value) in values.enumerated() {
            switch value {
            case let text as String: sqlite3_bind_text(s, Int32(index + 1), text, -1, Self.transient)
            case let number as Double: sqlite3_bind_double(s, Int32(index + 1), number)
            default: break
            }
        }
        sqlite3_step(s)
    }
}
