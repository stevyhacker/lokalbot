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

    @discardableResult
    func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Rowid of the most recent successful INSERT on this connection.
    func lastInsertRowID() -> Int64 {
        sqlite3_last_insert_rowid(db)
    }

    @discardableResult
    func run(_ sql: String, bind values: [Any] = []) -> Bool {
        withStatement(sql) { statement in
            run(statement, bind: values)
        } ?? false
    }

    /// Executes an already-prepared statement, resetting and rebinding it so
    /// callers can reuse the same statement for a batch of rows.
    @discardableResult
    func run(_ statement: OpaquePointer, bind values: [Any] = []) -> Bool {
        guard sqlite3_reset(statement) == SQLITE_OK else { return false }
        sqlite3_clear_bindings(statement)
        guard bind(values, to: statement) else { return false }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// Runs a group of writes atomically. Returning `false` from `body` rolls
    /// the transaction back, including when a prepared statement fails.
    @discardableResult
    func transaction(_ body: () -> Bool) -> Bool {
        guard exec("BEGIN IMMEDIATE TRANSACTION") else { return false }
        guard body(), exec("COMMIT") else {
            exec("ROLLBACK")
            return false
        }
        return true
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
        guard bind(values, to: statement) else { return nil }
        return body(statement)
    }

    private func bind(_ values: [Any], to statement: OpaquePointer) -> Bool {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case let text as String:
                result = sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case let number as Double:
                result = sqlite3_bind_double(statement, position, number)
            case let number as Int:
                result = sqlite3_bind_int64(statement, position, sqlite3_int64(number))
            case let number as Int64:
                result = sqlite3_bind_int64(statement, position, sqlite3_int64(number))
            case let data as Data:
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, position, bytes.baseAddress,
                                      Int32(data.count), Self.transient)
                }
            default:
                assertionFailure("SQLiteDatabase: unsupported bind type \(type(of: value))")
                return false
            }
            guard result == SQLITE_OK else { return false }
        }
        return true
    }
}
