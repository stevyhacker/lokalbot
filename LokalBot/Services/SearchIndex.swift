import Foundation
import SQLite3

/// SQLite + FTS5 full-text index (design doc §4.1) over meeting titles,
/// transcript segments and summaries. Lives at <storage root>/lokalbotv3.sqlite.
/// Segment-level rows let transcript hits deep-link to their audio timestamp.
/// macOS ships SQLite with FTS5 enabled, so this adds no dependency.
@MainActor
final class SearchIndex {

    private static let documentRowsMigration = "search-document-rows-v1"

    enum Kind: String {
        case title, segment, summary
    }

    struct Hit: Identifiable {
        let id = UUID()
        let meetingID: UUID
        let kind: Kind
        /// Segment start time for transcript hits; 0 otherwise.
        let start: TimeInterval
        /// Snippet with « » around matched terms.
        let snippet: String
        let speaker: String
    }

    private let database: SQLiteDatabase?

    init(databaseURL: URL) {
        guard let database = SQLiteDatabase(url: databaseURL) else {
            assertionFailure("SearchIndex: cannot open \(databaseURL.path)")
            self.database = nil
            return
        }
        self.database = database
        database.exec("""
            CREATE TABLE IF NOT EXISTS indexed_meetings (
                meeting_id TEXT PRIMARY KEY,
                source_mtime REAL NOT NULL
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(
                text,
                meeting_id UNINDEXED,
                kind UNINDEXED,
                start UNINDEXED,
                speaker UNINDEXED,
                tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TABLE IF NOT EXISTS search_document_rows (
                doc_rowid INTEGER PRIMARY KEY,
                meeting_id TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_search_document_rows_meeting_id
                ON search_document_rows(meeting_id);
            CREATE TABLE IF NOT EXISTS search_index_migrations (
                name TEXT PRIMARY KEY
            );
            """)
        Self.backfillDocumentRowsIfNeeded(in: database)
    }

    // MARK: - Indexing

    /// Re-index every meeting whose files changed since the last pass.
    func reindexAll(_ meetings: [Meeting], storage: StorageManager) {
        for meeting in meetings { reindex(meeting, storage: storage) }
    }

    func reindex(_ meeting: Meeting, storage: StorageManager) {
        let folder = meeting.folderURL(in: storage)
        let mtime = Self.latestMtime(in: folder)
        if let indexed = indexedMtime(of: meeting.id), indexed >= mtime { return }

        var documents = [Document(text: "\(meeting.title) \(meeting.appName)",
                                  kind: .title, start: 0, speaker: "")]

        if let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
           let transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
            for segment in transcript.segments {
                documents.append(Document(
                    text: segment.text,
                    kind: .segment,
                    start: segment.start,
                    speaker: transcript.displaySpeaker(for: segment.speaker)))
            }
        }
        if let summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"),
                                     encoding: .utf8) {
            documents.append(Document(text: summary, kind: .summary, start: 0, speaker: ""))
        }
        documents = documents.compactMap { document in
            let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Document(text: text, kind: document.kind,
                                                 start: document.start, speaker: document.speaker)
        }

        guard let database else { return }
        let meetingID = meeting.id.uuidString
        database.transaction {
            guard Self.deleteDocuments(for: meetingID, in: database) else { return false }
            let inserted = database.withStatement(
                "INSERT INTO docs (text, meeting_id, kind, start, speaker) VALUES (?1, ?2, ?3, ?4, ?5)"
            ) { documentStatement in
                database.withStatement(
                    "INSERT INTO search_document_rows (doc_rowid, meeting_id) VALUES (?1, ?2)"
                ) { mappingStatement in
                    for document in documents {
                        guard database.run(documentStatement, bind: [
                            document.text, meetingID, document.kind.rawValue,
                            document.start, document.speaker,
                        ]), database.run(mappingStatement, bind: [
                            database.lastInsertRowID(), meetingID,
                        ]) else { return false }
                    }
                    return true
                } ?? false
            } ?? false
            guard inserted else { return false }
            return database.run(
                "INSERT OR REPLACE INTO indexed_meetings (meeting_id, source_mtime) VALUES (?1, ?2)",
                bind: [meetingID, mtime])
        }
    }

    func remove(_ meetingID: UUID) {
        guard let database else { return }
        let id = meetingID.uuidString
        database.transaction {
            Self.deleteDocuments(for: id, in: database)
                && database.run("DELETE FROM indexed_meetings WHERE meeting_id = ?1", bind: [id])
        }
    }

    // MARK: - Query

    /// FTS5 search. By default terms are AND-ed and the last gets prefix matching
    /// (search-as-you-type). `matchAll: false` ORs the terms for recall, and
    /// `dropStopWords` strips function words first — both used by the chat tool to
    /// rescue natural-language questions. `kind` nil = all kinds.
    func search(_ query: String, kind: Kind? = nil, limit: Int = 60,
                matchAll: Bool = true, dropStopWords: Bool = false) -> [Hit] {
        guard let match = Self.ftsQuery(from: query, matchAll: matchAll,
                                        dropStopWords: dropStopWords),
              let database else { return [] }
        var sql = """
            SELECT meeting_id, kind, start, speaker,
                   snippet(docs, 0, '«', '»', '…', 14)
            FROM docs WHERE docs MATCH ?1
            """
        if kind != nil { sql += " AND kind = ?2" }
        sql += " ORDER BY rank LIMIT \(limit)"

        let values: [Any]
        if let kind {
            values = [match, kind.rawValue]
        } else {
            values = [match]
        }
        return database.query(sql, bind: values) { statement in
            guard let idText = sqlite3_column_text(statement, 0),
                  let meetingID = UUID(uuidString: String(cString: idText)),
                  let kindText = sqlite3_column_text(statement, 1),
                  let kind = Kind(rawValue: String(cString: kindText)),
                  let snippetText = sqlite3_column_text(statement, 4) else { return nil }
            let speaker = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            return Hit(meetingID: meetingID, kind: kind,
                       start: sqlite3_column_double(statement, 2),
                       snippet: String(cString: snippetText),
                       speaker: speaker)
        }
    }

    /// Common English function words that carry no retrieval signal. Stripped
    /// from natural-language queries (`dropStopWords`) so a question like
    /// "what did we decide about caching" doesn't AND `what/did/we/about`
    /// against the index and return nothing.
    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on", "at",
        "for", "with", "about", "as", "by", "from", "into", "is", "are", "was",
        "were", "be", "been", "being", "do", "does", "did", "doing", "have", "has",
        "had", "what", "when", "where", "who", "whom", "which", "why", "how",
        "we", "i", "you", "he", "she", "it", "they", "me", "us", "them", "my",
        "our", "your", "this", "that", "these", "those", "can", "could", "would",
        "should", "will", "shall", "may", "might", "must", "any", "some", "there",
    ]

    /// "fts5 syntax" is user-hostile; quote each term so punctuation can't
    /// produce a syntax error. `matchAll` ANDs the terms and prefix-matches the
    /// final one (search-as-you-type); pass `matchAll: false` to OR them for
    /// recall. `dropStopWords` strips function words first, keeping the originals
    /// only when every term was a stop word.
    static func ftsQuery(from raw: String, matchAll: Bool = true,
                         dropStopWords: Bool = false) -> String? {
        var terms = raw.split(whereSeparator: \.isWhitespace)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        if dropStopWords {
            let content = terms.filter { !stopWords.contains($0.lowercased()) }
            if !content.isEmpty { terms = content }
        }
        guard !terms.isEmpty else { return nil }
        guard matchAll else {
            return terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        }
        return terms.enumerated()
            .map { index, term in
                index == terms.count - 1 ? "\"\(term)\" *" : "\"\(term)\""
            }
            .joined(separator: " ")
    }

    // MARK: - Plumbing

    private struct Document {
        let text: String
        let kind: Kind
        let start: TimeInterval
        let speaker: String
    }

    private static func backfillDocumentRowsIfNeeded(in database: SQLiteDatabase) {
        guard !database.hasRow(
            "SELECT 1 FROM search_index_migrations WHERE name = ?1",
            bind: [documentRowsMigration]) else { return }
        database.transaction {
            database.run("DELETE FROM search_document_rows")
                && database.run("""
                    INSERT INTO search_document_rows (doc_rowid, meeting_id)
                    SELECT rowid, meeting_id FROM docs
                    WHERE meeting_id IS NOT NULL AND meeting_id != ''
                    """)
                && database.run(
                    "INSERT INTO search_index_migrations (name) VALUES (?1)",
                    bind: [documentRowsMigration])
        }
    }

    private static func deleteDocuments(for meetingID: String,
                                        in database: SQLiteDatabase) -> Bool {
        database.run("""
            DELETE FROM docs
            WHERE rowid IN (
                SELECT doc_rowid FROM search_document_rows WHERE meeting_id = ?1
            )
            """, bind: [meetingID])
            && database.run(
                "DELETE FROM search_document_rows WHERE meeting_id = ?1",
                bind: [meetingID])
    }

    private func indexedMtime(of meetingID: UUID) -> TimeInterval? {
        database?.firstDouble("SELECT source_mtime FROM indexed_meetings WHERE meeting_id = ?1",
                              bind: [meetingID.uuidString])
    }

    private static func latestMtime(in folder: URL) -> TimeInterval {
        ["meta.json", "transcript.json", "summary.md"].compactMap { name -> TimeInterval? in
            let url = folder.appendingPathComponent(name)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
        }.max() ?? 0
    }

}
