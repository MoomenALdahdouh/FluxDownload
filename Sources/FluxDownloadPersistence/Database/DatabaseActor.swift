import Foundation
import SQLite3
import FluxDownloadCore

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case text(String)
    case double(Double)
    case blob(Data)

    public var int64: Int64? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var string: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let value) = self { return value }
        return nil
    }
}

public actor DatabaseActor {
    nonisolated(unsafe) private var db: OpaquePointer?

    public init(path: URL) async throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let code = path.path.withCString { sqlite3_open_v2($0, &handle, flags, nil) }
        db = handle
        try check(code)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA busy_timeout=5000")
        try execute("PRAGMA temp_store=MEMORY")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    public func execute(_ sql: String, binds: [SQLValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, binds)
        let code = sqlite3_step(statement)
        if code != SQLITE_DONE && code != SQLITE_ROW {
            try check(code)
        }
    }

    public func query(_ sql: String, binds: [SQLValue] = []) throws -> [[String: SQLValue]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, binds)
        var rows: [[String: SQLValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            if code != SQLITE_ROW { try check(code) }
            rows.append(row(statement))
        }
        return rows
    }

    public func transaction<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try await body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func lastInsertRowID() -> Int64 {
        guard let db else { return 0 }
        return sqlite3_last_insert_rowid(db)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        try check(code)
        guard let statement else { throw FluxError.database("Failed to prepare statement.") }
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ binds: [SQLValue]) throws {
        for (index, value) in binds.enumerated() {
            let i = Int32(index + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(statement, i)
            case .int(let number):
                code = sqlite3_bind_int64(statement, i, number)
            case .double(let number):
                code = sqlite3_bind_double(statement, i, number)
            case .text(let text):
                code = sqlite3_bind_text(statement, i, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .blob(let data):
                code = data.withUnsafeBytes { raw in
                    sqlite3_bind_blob(statement, i, raw.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            }
            try check(code)
        }
    }

    private func row(_ statement: OpaquePointer) -> [String: SQLValue] {
        var result: [String: SQLValue] = [:]
        let count = sqlite3_column_count(statement)
        for i in 0..<count {
            let name = String(cString: sqlite3_column_name(statement, i))
            switch sqlite3_column_type(statement, i) {
            case SQLITE_INTEGER:
                result[name] = .int(sqlite3_column_int64(statement, i))
            case SQLITE_FLOAT:
                result[name] = .double(sqlite3_column_double(statement, i))
            case SQLITE_TEXT:
                if let cString = sqlite3_column_text(statement, i) {
                    result[name] = .text(String(cString: cString))
                } else {
                    result[name] = .null
                }
            case SQLITE_BLOB:
                if let bytes = sqlite3_column_blob(statement, i) {
                    let length = Int(sqlite3_column_bytes(statement, i))
                    result[name] = .blob(Data(bytes: bytes, count: length))
                } else {
                    result[name] = .null
                }
            default:
                result[name] = .null
            }
        }
        return result
    }

    private func check(_ code: Int32) throws {
        if code == SQLITE_OK || code == SQLITE_ROW || code == SQLITE_DONE { return }
        let message: String
        if let db, let cString = sqlite3_errmsg(db) {
            message = String(cString: cString)
        } else {
            message = "SQLite error \(code)"
        }
        throw FluxError.database(message)
    }
}
