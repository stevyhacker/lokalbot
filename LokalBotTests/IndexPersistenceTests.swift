import XCTest
@testable import LokalBot

@MainActor
final class IndexPersistenceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testTransactionRollsBackFailedPreparedBatchAndCommitsSuccessfulBatch() throws {
        let database = try XCTUnwrap(SQLiteDatabase(url: root.appendingPathComponent("batch.sqlite")))
        XCTAssertTrue(database.exec("CREATE TABLE values_table (value INTEGER UNIQUE NOT NULL)"))

        let failed = database.transaction {
            database.withStatement("INSERT INTO values_table (value) VALUES (?1)") { statement in
                database.run(statement, bind: [1])
                    && database.run(statement, bind: [1])
            } ?? false
        }

        XCTAssertFalse(failed)
        XCTAssertEqual(database.firstDouble("SELECT COUNT(*) FROM values_table"), 0)

        let committed = database.transaction {
            database.withStatement("INSERT INTO values_table (value) VALUES (?1)") { statement in
                (2...4).allSatisfy { database.run(statement, bind: [$0]) }
            } ?? false
        }

        XCTAssertTrue(committed)
        XCTAssertEqual(database.firstDouble("SELECT COUNT(*) FROM values_table"), 3)
    }

    func testSearchIndexBackfillsLegacyRowMappingAndRemovesOnlyTargetMeeting() throws {
        let url = root.appendingPathComponent("search-migration.sqlite")
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        XCTAssertTrue(database.exec("""
            CREATE TABLE indexed_meetings (
                meeting_id TEXT PRIMARY KEY,
                source_mtime REAL NOT NULL
            );
            CREATE VIRTUAL TABLE docs USING fts5(
                text,
                meeting_id UNINDEXED,
                kind UNINDEXED,
                start UNINDEXED,
                speaker UNINDEXED
            );
            """))

        let removedID = UUID()
        let retainedID = UUID()
        for id in [removedID, retainedID] {
            XCTAssertTrue(database.run(
                "INSERT INTO indexed_meetings (meeting_id, source_mtime) VALUES (?1, ?2)",
                bind: [id.uuidString, 100.0]))
        }
        XCTAssertTrue(database.run(
            "INSERT INTO docs (text, meeting_id, kind, start, speaker) VALUES (?1, ?2, ?3, ?4, ?5)",
            bind: ["legacyalpha", removedID.uuidString, "segment", 12.0, "Me"]))
        XCTAssertTrue(database.run(
            "INSERT INTO docs (text, meeting_id, kind, start, speaker) VALUES (?1, ?2, ?3, ?4, ?5)",
            bind: ["legacybeta", retainedID.uuidString, "segment", 24.0, "Them"]))

        let index = SearchIndex(databaseURL: url)

        XCTAssertEqual(database.firstDouble("SELECT COUNT(*) FROM search_document_rows"), 2)
        XCTAssertTrue(database.hasRow("""
            SELECT 1 FROM sqlite_master
            WHERE type = 'index' AND name = 'idx_search_document_rows_meeting_id'
            """))
        XCTAssertTrue(database.hasRow(
            "SELECT 1 FROM search_index_migrations WHERE name = ?1",
            bind: ["search-document-rows-v1"]))
        XCTAssertEqual(index.search("legacyalpha").map(\.meetingID), [removedID])
        XCTAssertEqual(index.search("legacybeta").map(\.meetingID), [retainedID])

        index.remove(removedID)

        XCTAssertEqual(database.firstDouble(
            "SELECT COUNT(*) FROM docs WHERE meeting_id = ?1",
            bind: [removedID.uuidString]), 0)
        XCTAssertEqual(database.firstDouble(
            "SELECT COUNT(*) FROM docs WHERE meeting_id = ?1",
            bind: [retainedID.uuidString]), 1)
        XCTAssertEqual(database.firstDouble(
            "SELECT COUNT(*) FROM search_document_rows WHERE meeting_id = ?1",
            bind: [removedID.uuidString]), 0)
        XCTAssertEqual(database.firstDouble(
            "SELECT COUNT(*) FROM search_document_rows WHERE meeting_id = ?1",
            bind: [retainedID.uuidString]), 1)
        XCTAssertFalse(database.hasRow(
            "SELECT 1 FROM indexed_meetings WHERE meeting_id = ?1",
            bind: [removedID.uuidString]))
        XCTAssertTrue(database.hasRow(
            "SELECT 1 FROM indexed_meetings WHERE meeting_id = ?1",
            bind: [retainedID.uuidString]))
        XCTAssertTrue(index.search("legacyalpha").isEmpty)
        XCTAssertEqual(index.search("legacybeta").map(\.meetingID), [retainedID])
    }

    func testSearchReindexRollsBackDocumentsAndMtimeWhenMappingInsertFails() throws {
        let storage = StorageManager(rootURL: root.appendingPathComponent("library", isDirectory: true))
        let meeting = Meeting(
            id: UUID(),
            title: "Atomic indexing",
            appName: "Tests",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_100),
            relativePath: "meetings/atomic",
            hasSystemTrack: false)
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcriptURL = folder.appendingPathComponent("transcript.json")
        try writeTranscript(text: "oldneedle remains searchable", to: transcriptURL,
                            modificationDate: Date(timeIntervalSince1970: 1_700_000_200))

        let databaseURL = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        let index = SearchIndex(databaseURL: databaseURL)
        index.reindex(meeting, storage: storage)
        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        let originalMtime = try XCTUnwrap(database.firstDouble(
            "SELECT source_mtime FROM indexed_meetings WHERE meeting_id = ?1",
            bind: [meeting.id.uuidString]))
        XCTAssertEqual(index.search("oldneedle").map(\.meetingID), [meeting.id])

        XCTAssertTrue(database.exec("""
            CREATE TRIGGER fail_search_mapping
            BEFORE INSERT ON search_document_rows
            BEGIN
                SELECT RAISE(ABORT, 'forced mapping failure');
            END;
            """))
        try writeTranscript(text: "newneedle must not replace the old row", to: transcriptURL,
                            modificationDate: Date(timeIntervalSince1970: 1_700_000_300))

        index.reindex(meeting, storage: storage)

        XCTAssertEqual(index.search("oldneedle").map(\.meetingID), [meeting.id])
        XCTAssertTrue(index.search("newneedle").isEmpty)
        XCTAssertEqual(database.firstDouble(
            "SELECT source_mtime FROM indexed_meetings WHERE meeting_id = ?1",
            bind: [meeting.id.uuidString]), originalMtime)
        XCTAssertEqual(database.firstDouble(
            "SELECT COUNT(*) FROM search_document_rows WHERE meeting_id = ?1",
            bind: [meeting.id.uuidString]), 2)
    }

    func testEmbeddingIndexAddsMeetingIDIndexWithoutDiscardingCurrentRows() throws {
        let url = root.appendingPathComponent("embedding-migration.sqlite")
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        XCTAssertTrue(database.exec("""
            CREATE TABLE embeddings (
                meeting_id TEXT NOT NULL,
                start REAL NOT NULL,
                text TEXT NOT NULL,
                vec BLOB NOT NULL
            );
            CREATE TABLE embedded_meetings (
                meeting_id TEXT PRIMARY KEY,
                source_mtime REAL NOT NULL,
                model_id TEXT NOT NULL DEFAULT ''
            );
            """))
        let meetingID = UUID().uuidString
        XCTAssertTrue(database.run(
            "INSERT INTO embeddings (meeting_id, start, text, vec) VALUES (?1, ?2, ?3, ?4)",
            bind: [meetingID, 0.0, "preserved", Data(repeating: 1, count: 8)]))
        XCTAssertTrue(database.run(
            "INSERT INTO embedded_meetings (meeting_id, source_mtime, model_id) VALUES (?1, ?2, ?3)",
            bind: [meetingID, 100.0, "qwen3-embedding-0.6b-q8"]))

        _ = EmbeddingIndex(databaseURL: url, storage: StorageManager(rootURL: root))

        XCTAssertTrue(database.hasRow("""
            SELECT 1 FROM sqlite_master
            WHERE type = 'index' AND name = 'idx_embeddings_meeting_id'
            """))
        XCTAssertEqual(database.firstDouble(
            "SELECT COUNT(*) FROM embeddings WHERE meeting_id = ?1",
            bind: [meetingID]), 1)
    }

    private func writeTranscript(text: String, to url: URL,
                                 modificationDate: Date) throws {
        let transcript = Transcript(
            segments: [.init(start: 12, end: 18, speaker: "me",
                             text: text, confidence: nil)],
            engine: "test")
        try JSONEncoder().encode(transcript).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: url.path)
    }
}
