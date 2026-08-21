import Foundation
import SQLite3

/// SQLite's own header defines these as macros, which Swift's C importer drops.
/// TRANSIENT tells SQLite to COPY the bound bytes before `bind` returns — the
/// alternative (STATIC) would require every bound String/Data to outlive the
/// statement, which nothing here guarantees.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite error \(code): \(message)" }
}

/// Minimal wrapper over the system libsqlite3 — deliberately not a dependency.
/// macOS ships SQLite, and the surface this app needs (a handful of statements
/// against two tables) is far smaller than what a package like GRDB would add
/// to a project that pins its four dependencies on purpose.
///
/// Opened FULLMUTEX so the handle is safe to use from any thread; callers still
/// serialize logically because a transaction spans several statements.
final class SQLiteDatabase {
    private let handle: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(path)"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError(code: code, message: message)
        }
        self.handle = handle
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String) throws {
        var raw: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &raw)
        guard code == SQLITE_OK else {
            let message = raw.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(raw)
            throw SQLiteError(code: code, message: message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
        return SQLiteStatement(handle: statement, database: handle)
    }

    /// Schema version, via SQLite's built-in `user_version` slot — no metadata
    /// table needed, and it is written atomically with the rest of a transaction.
    var userVersion: Int32 {
        guard let statement = try? prepare("PRAGMA user_version"),
              (try? statement.step()) == true,
              let value = statement.int(0) else { return 0 }
        return Int32(value)
    }

    func setUserVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    /// IMMEDIATE rather than DEFERRED: the write lock is taken up front, so a
    /// transaction that will write cannot fail partway through with SQLITE_BUSY
    /// after already having done half its work.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

/// A prepared statement. Binding is 1-indexed (SQLite's convention), column
/// reads are 0-indexed (also SQLite's convention) — the asymmetry is inherited,
/// not invented.
final class SQLiteStatement {
    private let handle: OpaquePointer
    private let database: OpaquePointer

    init(handle: OpaquePointer, database: OpaquePointer) {
        self.handle = handle
        self.database = database
    }

    deinit { sqlite3_finalize(handle) }

    // MARK: - Binding

    @discardableResult
    func bind(_ index: Int32, _ value: String?) -> Self {
        if let value {
            sqlite3_bind_text(handle, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(handle, index)
        }
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: UUID?) -> Self {
        bind(index, value?.uuidString)
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Data?) -> Self {
        guard let value else {
            sqlite3_bind_null(handle, index)
            return self
        }
        // An empty Data has a nil base address, which bind_blob would read as
        // NULL rather than as a zero-length blob.
        if value.isEmpty {
            _ = sqlite3_bind_zeroblob(handle, index, 0)
        } else {
            value.withUnsafeBytes { buffer in
                _ = sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
            }
        }
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Int) -> Self {
        sqlite3_bind_int64(handle, index, Int64(value))
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Date) -> Self {
        sqlite3_bind_double(handle, index, value.timeIntervalSince1970)
        return self
    }

    // MARK: - Stepping

    /// True when a row is available in the current cursor position.
    @discardableResult
    func step() throws -> Bool {
        let code = sqlite3_step(handle)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(code: code, message: String(cString: sqlite3_errmsg(database)))
        }
    }

    /// Steps a statement that returns no rows.
    func run() throws {
        while try step() {}
    }

    /// Rewinds a statement so it can be re-bound and run again — the point of
    /// preparing once and executing in a loop.
    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func forEachRow(_ body: (SQLiteStatement) throws -> Void) throws {
        while try step() { try body(self) }
    }

    // MARK: - Column reads

    func string(_ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: raw)
    }

    func uuid(_ column: Int32) -> UUID? {
        string(column).flatMap(UUID.init(uuidString:))
    }

    func data(_ column: Int32) -> Data? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let bytes = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    func int(_ column: Int32) -> Int? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(handle, column))
    }

    func date(_ column: Int32) -> Date? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(handle, column))
    }
}
