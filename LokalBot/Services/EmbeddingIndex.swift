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

    private let database: SQLiteDatabase?
    private let storage: StorageManager

    init(databaseURL: URL, storage: StorageManager) {
        self.storage = storage
        database = SQLiteDatabase(url: databaseURL)
        database?.exec("""
            CREATE TABLE IF NOT EXISTS embeddings (
                meeting_id TEXT NOT NULL, start REAL NOT NULL,
                text TEXT NOT NULL, vec BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS embedded_meetings (
                meeting_id TEXT PRIMARY KEY, source_mtime REAL NOT NULL);
            """)
    }

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
        database?.run("DELETE FROM embeddings WHERE meeting_id = ?1", bind: [meeting.id.uuidString])
        for (chunk, vector) in zip(chunks, vectors) {
            let vectorData = vector.withUnsafeBufferPointer { buffer -> Data in
                guard let baseAddress = buffer.baseAddress else { return Data() }
                return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Float>.stride)
            }
            database?.run(
                "INSERT INTO embeddings (meeting_id, start, text, vec) VALUES (?1, ?2, ?3, ?4)",
                bind: [meeting.id.uuidString, chunk.start, String(chunk.text.prefix(300)), vectorData])
        }
        database?.run(
            "INSERT OR REPLACE INTO embedded_meetings (meeting_id, source_mtime) VALUES (?1, ?2)",
            bind: [meeting.id.uuidString, mtime])
    }

    func remove(_ meetingID: UUID) {
        database?.run("DELETE FROM embeddings WHERE meeting_id = ?1", bind: [meetingID.uuidString])
        database?.run("DELETE FROM embedded_meetings WHERE meeting_id = ?1", bind: [meetingID.uuidString])
    }

    // MARK: - Query

    var hasEmbeddings: Bool {
        database?.hasRow("SELECT 1 FROM embeddings LIMIT 1") ?? false
    }

    func search(_ query: String, limit: Int = 10) async -> [Hit] {
        guard let database, hasEmbeddings else { return [] }
        guard let queryVector = try? await Self.embed([query], prefix: "search_query: ",
                                                      storage: storage).first else { return [] }
        let hits: [Hit] = database.query("SELECT meeting_id, start, text, vec FROM embeddings") { statement in
            guard let idText = sqlite3_column_text(statement, 0),
                  let meetingID = UUID(uuidString: String(cString: idText)),
                  let blob = sqlite3_column_blob(statement, 3) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, 3)) / 4
            guard count == queryVector.count else { return nil }
            let vector = blob.withMemoryRebound(to: Float.self, capacity: count) {
                Array(UnsafeBufferPointer(start: $0, count: count))
            }
            let score = zip(queryVector, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            guard score > 0.45 else { return nil }
            return Hit(meetingID: meetingID,
                       start: sqlite3_column_double(statement, 1),
                       text: String(cString: sqlite3_column_text(statement, 2)),
                       score: score)
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
        guard ModelFileValidator.looksLikeGGUF(temp) else {
            throw TextEngineError.badResponse("embedding model download was not a GGUF model")
        }
        try? FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: temp, to: path)
        return path
    }

    // MARK: - Plumbing

    private func indexedMtime(_ id: UUID) -> TimeInterval? {
        database?.firstDouble("SELECT source_mtime FROM embedded_meetings WHERE meeting_id = ?1",
                              bind: [id.uuidString])
    }
}
