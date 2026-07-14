import Foundation
import SQLite3

/// Persists the post-meeting processing queue in lokalbotv3.sqlite so a crash,
/// force-quit, or reboot mid-transcription doesn't silently drop the job — the
/// in-memory queue in `ProcessingPipeline` used to be the only record of what
/// still needed processing.
///
/// Own connection to the shared database file, same pattern as `SearchIndex` /
/// `ActivityStore` / `EmbeddingIndex`. A row lives for the duration of a job:
/// inserted on enqueue, deleted on success. `attempts` counts processing
/// *starts* (not failures), so a job that crashes the app mid-flight still
/// burns an attempt and a poison-pill meeting can't crash-loop launch resume
/// forever.
final class PipelineJobStore {

    struct PendingJob {
        let meetingID: UUID
        let transcribe: Bool
        let summarize: Bool
        let attempts: Int
    }

    /// Launch auto-resume gives up after this many processing starts; an
    /// explicit user re-enqueue resets the counter and tries again.
    static let maxAutoResumeAttempts = 3

    private let database: SQLiteDatabase?
    private let databaseURL: URL

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
        database = SQLiteDatabase(url: databaseURL)
        do {
            try requiredDatabase().execute("""
                CREATE TABLE IF NOT EXISTS pipeline_jobs (
                    meeting_id TEXT PRIMARY KEY,
                    transcribe INTEGER NOT NULL,
                    summarize INTEGER NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    enqueued_at REAL NOT NULL
                );
                """)
        } catch {
            lokalbotLog("pipeline queue initialization failed: \(error.localizedDescription)")
        }
    }

    private func requiredDatabase() throws -> SQLiteDatabase {
        guard let database else {
            throw SQLiteDatabase.DatabaseError.unavailable(path: databaseURL.path)
        }
        return database
    }

    /// Record a fresh enqueue. Resets `attempts`: an explicit re-enqueue is a
    /// deliberate retry, not a crash-loop continuation.
    @discardableResult
    func enqueue(meetingID: UUID, transcribe: Bool, summarize: Bool,
                 at date: Date = Date()) -> Bool {
        write("enqueue") { database in
            try database.runChecked("""
                INSERT INTO pipeline_jobs (meeting_id, transcribe, summarize, attempts, enqueued_at)
                VALUES (?1, ?2, ?3, 0, ?4)
                ON CONFLICT(meeting_id) DO UPDATE SET
                    transcribe = excluded.transcribe,
                    summarize = excluded.summarize,
                    attempts = 0,
                    enqueued_at = excluded.enqueued_at
                """, bind: [meetingID.uuidString, transcribe ? 1 : 0, summarize ? 1 : 0,
                             date.timeIntervalSince1970])
        }
    }

    /// Burn one attempt the moment processing starts, so a crash mid-job is
    /// already counted when the row is read back on the next launch.
    @discardableResult
    func markStarted(meetingID: UUID) -> Bool {
        write("mark started") { database in
            try database.runChecked(
                "UPDATE pipeline_jobs SET attempts = attempts + 1 WHERE meeting_id = ?1",
                bind: [meetingID.uuidString])
        }
    }

    @discardableResult
    func markCompleted(meetingID: UUID) -> Bool {
        write("mark completed") { database in
            try database.runChecked(
                "DELETE FROM pipeline_jobs WHERE meeting_id = ?1",
                bind: [meetingID.uuidString])
        }
    }

    /// Jobs eligible for launch auto-resume, oldest first.
    func pendingJobs() -> [PendingJob] {
        do {
            return try requiredDatabase().queryChecked("""
                SELECT meeting_id, transcribe, summarize, attempts FROM pipeline_jobs
                WHERE attempts < ?1 ORDER BY enqueued_at
                """, bind: [Self.maxAutoResumeAttempts]) { statement -> PendingJob? in
                guard let text = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: text)) else { return nil }
                return PendingJob(meetingID: id,
                                  transcribe: sqlite3_column_int64(statement, 1) != 0,
                                  summarize: sqlite3_column_int64(statement, 2) != 0,
                                  attempts: Int(sqlite3_column_int64(statement, 3)))
            }
        } catch {
            lokalbotLog("pipeline queue read failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Drop rows whose meeting no longer exists (deleted from the library
    /// between the crash and this launch).
    @discardableResult
    func prune(existing meetingIDs: Set<UUID>) -> Bool {
        do {
            let database = try requiredDatabase()
            let rows = try database.queryChecked(
                "SELECT meeting_id FROM pipeline_jobs") { statement -> String? in
                sqlite3_column_text(statement, 0).map { String(cString: $0) }
            }
            let staleIDs = rows.filter {
                UUID(uuidString: $0).map { !meetingIDs.contains($0) } ?? true
            }
            try database.withTransaction {
                for id in staleIDs {
                    try database.runChecked(
                        "DELETE FROM pipeline_jobs WHERE meeting_id = ?1", bind: [id])
                }
            }
            return true
        } catch {
            lokalbotLog("pipeline queue prune failed: \(error.localizedDescription)")
            return false
        }
    }

    private func write(_ operation: String,
                       body: (SQLiteDatabase) throws -> Void) -> Bool {
        do {
            try body(requiredDatabase())
            return true
        } catch {
            lokalbotLog("pipeline queue \(operation) failed: \(error.localizedDescription)")
            return false
        }
    }
}
