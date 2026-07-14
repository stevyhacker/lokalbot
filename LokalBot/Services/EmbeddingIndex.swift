import Foundation
import SQLite3

/// Coalesces expensive embedding-model preparation by destination. Waiters
/// can cancel independently; the shared operation is canceled only after its
/// final waiter leaves, so one abandoned search cannot break active indexing.
actor EmbeddingModelPreparationCoordinator {
    typealias Operation = @Sendable () async throws -> URL

    private struct Flight {
        let id: UUID
        let task: Task<URL, Error>
        var waiters: [UUID: CheckedContinuation<URL, Error>]
    }

    private var flights: [String: Flight] = [:]

    func prepare(key: String, operation: @escaping Operation) async throws -> URL {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                enqueue(
                    waiterID: waiterID,
                    key: key,
                    operation: operation,
                    continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID, key: key) }
        }
    }

    func waiterCount(for key: String) -> Int {
        flights[key]?.waiters.count ?? 0
    }

    private func enqueue(
        waiterID: UUID,
        key: String,
        operation: @escaping Operation,
        continuation: CheckedContinuation<URL, Error>
    ) {
        if var flight = flights[key] {
            flight.waiters[waiterID] = continuation
            flights[key] = flight
            return
        }
        let flightID = UUID()
        let task = Task { try await operation() }
        flights[key] = Flight(
            id: flightID,
            task: task,
            waiters: [waiterID: continuation])
        Task { [weak self] in
            let result = await task.result
            await self?.finish(key: key, flightID: flightID, result: result)
        }
    }

    private func cancel(waiterID: UUID, key: String) {
        guard var flight = flights[key],
              let continuation = flight.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
        // Keep the preparation flight alive even when its current waiter set
        // becomes empty. Download/install cancellation is not guaranteed to be
        // instantaneous; retaining the flight lets a later caller rejoin it
        // instead of racing a second install against a still-unwinding first.
        flights[key] = flight
    }

    private func finish(key: String, flightID: UUID, result: Result<URL, Error>) {
        guard let flight = flights[key], flight.id == flightID else { return }
        flights[key] = nil
        for continuation in flight.waiters.values {
            continuation.resume(with: result)
        }
    }
}

/// M6 semantic layer (design §4.1): transcript/summary chunks embedded with
/// Qwen3-Embedding 0.6B GGUF, served by the second llama-server instance.
/// Vectors live in SQLite; query = brute-force cosine (normalized dot) —
/// instant at personal-library scale, no extra dependency.
@MainActor
final class EmbeddingIndex {

    struct Hit: Identifiable, Sendable {
        let id = UUID()
        let meetingID: UUID
        let start: TimeInterval
        let text: String
        let score: Float
    }

    private static let modelID = "qwen3-embedding-0.6b-q8"
    nonisolated private static let modelFile = "Qwen3-Embedding-0.6B-Q8_0.gguf"
    nonisolated private static let modelBytes: Int64 = 639_150_592
    nonisolated private static let modelSHA256 = "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439"
    nonisolated private static let modelURL =
        "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/370f27d7550e0def9b39c1f16d3fbaa13aa67728/Qwen3-Embedding-0.6B-Q8_0.gguf"
    private static let documentPrefix = "Document for meeting search: "
    private static let queryPrefix = """
        Instruct: Retrieve relevant meeting transcript and summary chunks for the user's query.
        Query:
        """
    private static let modelPreparation = EmbeddingModelPreparationCoordinator()

    private let database: SQLiteDatabase?
    private let storage: StorageManager
    private var locallyDeletedMeetingIDs: Set<UUID> = []

    init(databaseURL: URL, storage: StorageManager) {
        self.storage = storage
        database = SQLiteDatabase(url: databaseURL)
        database?.exec("""
            CREATE TABLE IF NOT EXISTS embeddings (
                meeting_id TEXT NOT NULL, start REAL NOT NULL,
                text TEXT NOT NULL, vec BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS embedded_meetings (
                meeting_id TEXT PRIMARY KEY, source_mtime REAL NOT NULL,
                model_id TEXT NOT NULL DEFAULT '');
            CREATE INDEX IF NOT EXISTS idx_embeddings_meeting_id
                ON embeddings(meeting_id);
            CREATE TABLE IF NOT EXISTS deleted_meetings (
                meeting_id TEXT PRIMARY KEY,
                deleted_at REAL NOT NULL
            );
            """)
        if database?.hasRow(
            "SELECT 1 FROM pragma_table_info('embedded_meetings') WHERE name = 'model_id'"
        ) == false {
            database?.exec(
                "ALTER TABLE embedded_meetings ADD COLUMN model_id TEXT NOT NULL DEFAULT '';")
        }
        if let database {
            database.transaction {
                database.run("""
                DELETE FROM embeddings
                WHERE meeting_id IN (
                    SELECT meeting_id FROM embedded_meetings WHERE model_id != ?1
                )
                """, bind: [Self.modelID])
                    && database.run(
                    "DELETE FROM embedded_meetings WHERE model_id != ?1",
                    bind: [Self.modelID])
            }
        }
        _ = reconcileDeletedMeetings()
    }

    // MARK: - Indexing

    func reindexAll(_ meetings: [Meeting]) async {
        for meeting in meetings {
            guard !Task.isCancelled else { return }
            try? await index(meeting)
        }
    }

    func index(_ meeting: Meeting) async throws {
        guard !isDeleted(meeting.id) else { return }
        let folder = meeting.folderURL(in: storage)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
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
                current += "\(transcript.displaySpeaker(for: segment.speaker)): \(segment.text)\n"
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

        let vectors = try await Self.embed(chunks.map(\.text), prefix: Self.documentPrefix,
                                           storage: storage)
        try Task.checkCancellation()
        guard vectors.count == chunks.count else {
            throw TextEngineError.badResponse(
                "embedding response contained \(vectors.count) vectors for \(chunks.count) chunks")
        }
        let rows = zip(chunks, vectors).map { chunk, vector in
            let vectorData = vector.withUnsafeBufferPointer { buffer -> Data in
                guard let baseAddress = buffer.baseAddress else { return Data() }
                return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Float>.stride)
            }
            return (start: chunk.start, text: String(chunk.text.prefix(300)), vectorData: vectorData)
        }

        guard let database else { return }
        let meetingID = meeting.id.uuidString
        database.transaction {
            do {
                guard try !database.hasRowChecked(
                    "SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1",
                    bind: [meetingID]),
                      FileManager.default.fileExists(atPath: folder.path) else { return true }
                // Embedding can suspend for minutes. Recheck freshness under
                // BEGIN IMMEDIATE so an older request cannot replace a newer
                // snapshot after it finally receives vectors.
                if let indexed = try database.firstDoubleChecked(
                    """
                    SELECT source_mtime FROM embedded_meetings
                    WHERE meeting_id = ?1 AND model_id = ?2
                    """, bind: [meetingID, Self.modelID]), indexed >= mtime {
                    return true
                }
            } catch {
                return false
            }
            guard database.run(
                "DELETE FROM embeddings WHERE meeting_id = ?1",
                bind: [meetingID]) else { return false }
            let inserted = database.withStatement(
                "INSERT INTO embeddings (meeting_id, start, text, vec) VALUES (?1, ?2, ?3, ?4)"
            ) { statement in
                for row in rows {
                    guard database.run(statement, bind: [
                        meetingID, row.start, row.text, row.vectorData,
                    ]) else { return false }
                }
                return true
            } ?? false
            guard inserted else { return false }
            return database.run(
                "INSERT OR REPLACE INTO embedded_meetings (meeting_id, source_mtime, model_id) VALUES (?1, ?2, ?3)",
                bind: [meetingID, mtime, Self.modelID])
        }
    }

    @discardableResult
    func remove(_ meetingID: UUID) -> Bool {
        noteDeletion(meetingID)
        guard let database else { return false }
        return Self.remove(meetingID, in: database)
    }

    /// Immediately closes the async rank/delete race without waiting for a
    /// potentially busy SQLite writer. AppState follows this in-memory marker
    /// with durable utility-worker cleanup.
    func noteDeletion(_ meetingID: UUID) {
        locallyDeletedMeetingIDs.insert(meetingID)
    }

    /// Utility-worker entry point used by AppState deletion. It deliberately
    /// opens its own FULLMUTEX connection so SQLite's busy timeout can never
    /// stall the main actor.
    @discardableResult
    nonisolated static func remove(_ meetingID: UUID, databaseURL: URL) -> Bool {
        guard let database = SQLiteDatabase(url: databaseURL) else { return false }
        return remove(meetingID, in: database)
    }

    /// Completes cleanup for tombstones whose original deletion was
    /// interrupted. The tombstone remains the source of truth and query paths
    /// exclude it while these reconstructible rows are being removed.
    @discardableResult
    func reconcileDeletedMeetings() -> Bool {
        guard let database else { return false }
        return Self.reconcileDeletedMeetings(in: database)
    }

    @discardableResult
    nonisolated static func reconcileDeletedMeetings(databaseURL: URL) -> Bool {
        guard let database = SQLiteDatabase(url: databaseURL) else { return false }
        return reconcileDeletedMeetings(in: database)
    }

    // MARK: - Query

    var hasEmbeddings: Bool {
        database?.hasRow("""
            SELECT 1 FROM embeddings
            WHERE NOT EXISTS (
                SELECT 1 FROM deleted_meetings AS deleted
                WHERE deleted.meeting_id = embeddings.meeting_id
            )
            LIMIT 1
            """) ?? false
    }

    func search(_ query: String, limit: Int = 10) async -> [Hit] {
        guard limit > 0, let database, hasEmbeddings else { return [] }
        guard let queryVector = try? await Self.embed([query], prefix: Self.queryPrefix,
                                                      storage: storage).first else { return [] }
        let candidates: [Candidate] = database.query(
            """
            SELECT meeting_id, start, text, vec FROM embeddings
            WHERE NOT EXISTS (
                SELECT 1 FROM deleted_meetings AS deleted
                WHERE deleted.meeting_id = embeddings.meeting_id
            )
            """
        ) { statement in
            guard let idText = sqlite3_column_text(statement, 0),
                  let meetingID = UUID(uuidString: String(cString: idText)),
                  let text = sqlite3_column_text(statement, 2),
                  let blob = sqlite3_column_blob(statement, 3) else { return nil }
            let byteCount = Int(sqlite3_column_bytes(statement, 3))
            guard byteCount == queryVector.count * MemoryLayout<Float>.stride else { return nil }
            return Candidate(
                meetingID: meetingID,
                start: sqlite3_column_double(statement, 1),
                text: String(cString: text),
                vector: Data(bytes: blob, count: byteCount))
        }
        let ranked = await Task.detached(priority: .userInitiated) {
            Self.rank(candidates, against: queryVector, limit: limit)
        }.value
        guard !Task.isCancelled else { return [] }
        // Ranking yields the main actor. A meeting can be deleted after the
        // candidate snapshot but before ranking completes, so validate again
        // synchronously before publishing any hit.
        return liveHits(from: ranked)
    }

    func liveHits(from hits: [Hit]) -> [Hit] {
        hits.filter { !isDeleted($0.meetingID) }
    }

    private struct Candidate: Sendable {
        let meetingID: UUID
        let start: TimeInterval
        let text: String
        let vector: Data
    }

    /// Cosine scoring is the expensive part of brute-force retrieval. Keep it
    /// off the main actor and retain only the best `limit` rows instead of
    /// allocating and sorting a hit for every embedding in the library.
    nonisolated private static func rank(
        _ candidates: [Candidate],
        against queryVector: [Float],
        limit: Int
    ) -> [Hit] {
        var best: [Hit] = []
        best.reserveCapacity(limit)

        for candidate in candidates {
            let score: Float = candidate.vector.withUnsafeBytes { bytes in
                var total: Float = 0
                for index in queryVector.indices {
                    let value = bytes.loadUnaligned(
                        fromByteOffset: index * MemoryLayout<Float>.stride,
                        as: Float.self)
                    total += queryVector[index] * value
                }
                return total
            }
            guard score > 0.45 else { continue }
            let hit = Hit(meetingID: candidate.meetingID, start: candidate.start,
                          text: candidate.text, score: score)
            if best.count < limit {
                best.append(hit)
            } else if let weakest = best.indices.min(by: { best[$0].score < best[$1].score }),
                      score > best[weakest].score {
                best[weakest] = hit
            }
        }
        return best.sorted { $0.score > $1.score }
    }

    // MARK: - Embedding via llama-server

    private static func embed(_ texts: [String], prefix: String,
                              storage: StorageManager) async throws -> [[Float]] {
        let modelPath = try await ensureModel(storage: storage)
        return try await InferenceBroker.shared.withLease(
            .embedder, model: modelPath, priority: .background,
            purpose: "embeddings") { () async throws -> [[Float]] in
            var request = URLRequest(url: LlamaServer.embedder.baseURL
                .appendingPathComponent("embeddings"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let authenticationToken = await LlamaServer.embedder.authenticationToken()
            request.setValue("Bearer \(authenticationToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 120
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "input": texts.map { prefix + $0 },
                "model": Self.modelID,
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
    }

    private static func ensureModel(storage: StorageManager) async throws -> URL {
        let storageRoot = storage.rootURL
        let key = storageRoot.appendingPathComponent("models/\(modelFile)")
            .standardizedFileURL.resolvingSymlinksInPath().path
        return try await modelPreparation.prepare(key: key) {
            try await prepareModel(storageRoot: storageRoot)
        }
    }

    private nonisolated static func prepareModel(storageRoot: URL) async throws -> URL {
        let folder = storageRoot.appendingPathComponent("models", isDirectory: true)
        let path = folder.appendingPathComponent(modelFile)
        if ModelFileValidator.looksLikeGGUF(path),
           await DownloadIntegrity.verifiedExisting(
               at: path, expectedBytes: modelBytes, expectedSHA256: modelSHA256) {
            return path
        }
        DownloadIntegrity.removeFileAndMarker(at: path)
        let stashed = try await ParallelRangeDownloader.download(
            from: URL(string: modelURL)!, session: .shared) { _ in }
        do {
            guard ModelFileValidator.looksLikeGGUF(stashed) else {
                throw TextEngineError.badResponse("embedding model download was not a GGUF model")
            }
            try await DownloadIntegrity.verifyDownloaded(
                at: stashed, expectedBytes: modelBytes, expectedSHA256: modelSHA256)
        } catch {
            DownloadFileRescuer.cleanup(stashed)
            throw error
        }
        try DownloadFileRescuer.install(stashed: stashed, to: path)
        DownloadIntegrity.removeFileAndMarker(at: stashed)
        try DownloadIntegrity.markInstalled(
            at: path, expectedBytes: modelBytes, expectedSHA256: modelSHA256)
        return path
    }

    // MARK: - Plumbing

    private func indexedMtime(_ id: UUID) -> TimeInterval? {
        database?.firstDouble(
            "SELECT source_mtime FROM embedded_meetings WHERE meeting_id = ?1 AND model_id = ?2",
            bind: [id.uuidString, Self.modelID])
    }

    private func isDeleted(_ id: UUID) -> Bool {
        if locallyDeletedMeetingIDs.contains(id) { return true }
        guard let database else { return true }
        return (try? database.hasRowChecked(
            "SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1",
            bind: [id.uuidString])) != false
    }

    nonisolated private static func remove(_ meetingID: UUID,
                                           in database: SQLiteDatabase) -> Bool {
        let id = meetingID.uuidString
        let marked = database.transaction {
            database.run(
                "INSERT OR IGNORE INTO deleted_meetings (meeting_id, deleted_at) VALUES (?1, ?2)",
                bind: [id, Date().timeIntervalSince1970])
        }
        guard marked else { return false }
        guard let tables = cleanupTablePresence(in: database) else { return false }
        return database.transaction {
            (!tables.embeddings
             || database.run("DELETE FROM embeddings WHERE meeting_id = ?1", bind: [id]))
                && (!tables.meetings
                    || database.run(
                        "DELETE FROM embedded_meetings WHERE meeting_id = ?1",
                        bind: [id]))
        }
    }

    nonisolated private static func reconcileDeletedMeetings(
        in database: SQLiteDatabase
    ) -> Bool {
        guard let tables = cleanupTablePresence(in: database) else { return false }
        return database.transaction {
            (!tables.embeddings
             || database.run("""
                 DELETE FROM embeddings
                 WHERE meeting_id IN (SELECT meeting_id FROM deleted_meetings)
                 """))
                && (!tables.meetings
                    || database.run("""
                        DELETE FROM embedded_meetings
                        WHERE meeting_id IN (SELECT meeting_id FROM deleted_meetings)
                        """))
        }
    }

    nonisolated private static func cleanupTablePresence(
        in database: SQLiteDatabase
    ) -> (embeddings: Bool, meetings: Bool)? {
        do {
            return (
                try database.hasRowChecked(
                    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'embeddings'"),
                try database.hasRowChecked(
                    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'embedded_meetings'")
            )
        } catch {
            return nil
        }
    }
}
