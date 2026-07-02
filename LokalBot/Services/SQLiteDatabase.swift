import Foundation
import SQLite3

final class SQLiteDatabase {
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let db: OpaquePointer

    init?(url: URL) {
        var opened: OpaquePointer?
        guard sqlite3_open(url.path, &opened) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            return nil
        }
        db = opened
    }

    deinit {
        sqlite3_close(db)
    }

    func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// Rowid of the most recent successful INSERT on this connection.
    func lastInsertRowID() -> Int64 {
        sqlite3_last_insert_rowid(db)
    }

    func run(_ sql: String, bind values: [Any] = []) {
        withStatement(sql, bind: values) { statement in
            sqlite3_step(statement)
        }
    }

    func query<T>(_ sql: String, bind values: [Any] = [], row: (OpaquePointer) -> T?) -> [T] {
        withStatement(sql, bind: values) { statement in
            var rows: [T] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let value = row(statement) {
                    rows.append(value)
                }
            }
            return rows
        } ?? []
    }

    func firstDouble(_ sql: String, bind values: [Any] = []) -> Double? {
        withStatement(sql, bind: values) { statement in
            sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_double(statement, 0) : nil
        } ?? nil
    }

    func hasRow(_ sql: String, bind values: [Any] = []) -> Bool {
        withStatement(sql, bind: values) { statement in
            sqlite3_step(statement) == SQLITE_ROW
        } ?? false
    }

    @discardableResult
    func withStatement<T>(_ sql: String, bind values: [Any] = [], _ body: (OpaquePointer) -> T) -> T? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(values, to: statement)
        return body(statement)
    }

    private func bind(_ values: [Any], to statement: OpaquePointer) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let text as String:
                sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case let number as Double:
                sqlite3_bind_double(statement, position, number)
            case let number as Int:
                sqlite3_bind_int64(statement, position, sqlite3_int64(number))
            case let number as Int64:
                sqlite3_bind_int64(statement, position, sqlite3_int64(number))
            case let data as Data:
                _ = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, position, bytes.baseAddress,
                                      Int32(data.count), Self.transient)
                }
            default:
                assertionFailure("SQLiteDatabase: unsupported bind type \(type(of: value))")
            }
        }
    }
}
