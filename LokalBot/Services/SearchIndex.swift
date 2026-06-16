import Foundation
import SQLite3

/// SQLite + FTS5 full-text index (design doc §4.1) over meeting titles,
/// transcript segments and summaries. Lives at <storage root>/botinav2.sqlite.
/// Segment-level rows let transcript hits deep-link to their audio timestamp.
/// macOS ships SQLite with FTS5 enabled, so this adds no dependency.
@MainActor
final class SearchIndex {

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

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL) {
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            assertionFailure("SearchIndex: cannot open \(databaseURL.path)")
            db = nil
            return
        }
        exec("""
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
            """)
    }

    deinit {
        sqlite3_close(db)
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

        run("DELETE FROM docs WHERE meeting_id = ?1", bind: [meeting.id.uuidString])
        insert(text: "\(meeting.title) \(meeting.appName)", meeting: meeting.id,
               kind: .title, start: 0, speaker: "")

        if let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
           let transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
            for segment in transcript.segments {
                insert(text: segment.text, meeting: meeting.id, kind: .segment,
                       start: segment.start, speaker: segment.speaker)
            }
        }
        if let summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"),
                                     encoding: .utf8) {
            insert(text: summary, meeting: meeting.id, kind: .summary, start: 0, speaker: "")
        }
        run("INSERT OR REPLACE INTO indexed_meetings (meeting_id, source_mtime) VALUES (?1, ?2)",
            bind: [meeting.id.uuidString, mtime])
    }

    func remove(_ meetingID: UUID) {
        run("DELETE FROM docs WHERE meeting_id = ?1", bind: [meetingID.uuidString])
        run("DELETE FROM indexed_meetings WHERE meeting_id = ?1", bind: [meetingID.uuidString])
    }

    // MARK: - Query

    /// FTS5 search; terms are AND-ed, the last gets prefix matching so
    /// search-as-you-type works. `kind` nil = all kinds.
    func search(_ query: String, kind: Kind? = nil, limit: Int = 60) -> [Hit] {
        guard let match = Self.ftsQuery(from: query), db != nil else { return [] }
        var sql = """
            SELECT meeting_id, kind, start, speaker,
                   snippet(docs, 0, '«', '»', '…', 14)
            FROM docs WHERE docs MATCH ?1
            """
        if kind != nil { sql += " AND kind = ?2" }
        sql += " ORDER BY rank LIMIT \(limit)"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, match, -1, Self.transient)
        if let kind { sqlite3_bind_text(statement, 2, kind.rawValue, -1, Self.transient) }

        var hits: [Hit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let meetingID = UUID(uuidString: String(cString: idText)),
                  let kindText = sqlite3_column_text(statement, 1),
                  let kind = Kind(rawValue: String(cString: kindText)),
                  let snippetText = sqlite3_column_text(statement, 4) else { continue }
            let speaker = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            hits.append(Hit(meetingID: meetingID, kind: kind,
                            start: sqlite3_column_double(statement, 2),
                            snippet: String(cString: snippetText),
                            speaker: speaker))
        }
        return hits
    }

    /// "fts5 syntax" is user-hostile; quote each term so punctuation can't
    /// produce a syntax error, and prefix-match the final term.
    static func ftsQuery(from raw: String) -> String? {
        let terms = raw.split(whereSeparator: \.isWhitespace)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms.enumerated()
            .map { index, term in
                index == terms.count - 1 ? "\"\(term)\" *" : "\"\(term)\""
            }
            .joined(separator: " ")
    }

    // MARK: - Plumbing

    private func insert(text: String, meeting: UUID, kind: Kind,
                        start: TimeInterval, speaker: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run("INSERT INTO docs (text, meeting_id, kind, start, speaker) VALUES (?1, ?2, ?3, ?4, ?5)",
            bind: [trimmed, meeting.uuidString, kind.rawValue, start, speaker])
    }

    private func indexedMtime(of meetingID: UUID) -> TimeInterval? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT source_mtime FROM indexed_meetings WHERE meeting_id = ?1",
                                 -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, meetingID.uuidString, -1, Self.transient)
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_double(statement, 0) : nil
    }

    private static func latestMtime(in folder: URL) -> TimeInterval {
        ["meta.json", "transcript.json", "summary.md"].compactMap { name -> TimeInterval? in
            let url = folder.appendingPathComponent(name)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
        }.max() ?? 0
    }

    private func run(_ sql: String, bind values: [Any]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case let number as Double: sqlite3_bind_double(statement, position, number)
            default: assertionFailure("SearchIndex: unsupported bind type")
            }
        }
        sqlite3_step(statement)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
