import Foundation
import FluxDownloadCore

public struct Migration: Sendable {
    public let version: Int
    public let name: String
    public let sql: String

    public init(version: Int, name: String, sql: String) {
        self.version = version
        self.name = name
        self.sql = sql
    }
}

public enum Migrations {
    public static let all: [Migration] = [
        Migration(version: 1, name: "initial", sql: Self.v1)
    ]

    public static func apply(on db: DatabaseActor) async throws {
        try await db.execute(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                applied_at REAL NOT NULL
            )
            """
        )
        let appliedRows = try await db.query("SELECT version FROM schema_migrations")
        let applied = Set(appliedRows.compactMap { $0["version"]?.int64 }.map { Int($0) })
        for migration in all where !applied.contains(migration.version) {
            try await db.transaction {
                for statement in splitStatements(migration.sql) {
                    try await db.execute(statement)
                }
                try await db.execute(
                    "INSERT INTO schema_migrations(version, name, applied_at) VALUES (?, ?, ?)",
                    binds: [.int(Int64(migration.version)), .text(migration.name), .double(Date().timeIntervalSince1970)]
                )
            }
        }
    }

    private static func splitStatements(_ sql: String) -> [String] {
        sql.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static let v1 = """
    CREATE TABLE downloads (
        id TEXT PRIMARY KEY,
        url TEXT NOT NULL,
        original_url TEXT NOT NULL,
        final_url TEXT,
        filename TEXT NOT NULL,
        file_extension TEXT NOT NULL DEFAULT '',
        mime_type TEXT,
        size INTEGER,
        downloaded_bytes INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        category_id TEXT,
        queue_id TEXT,
        priority INTEGER NOT NULL DEFAULT 1,
        created_at REAL NOT NULL,
        started_at REAL,
        completed_at REAL,
        save_directory TEXT NOT NULL,
        temporary_path TEXT,
        final_path TEXT,
        referrer TEXT,
        user_agent TEXT,
        credential_ref TEXT,
        cookie_ref TEXT,
        retry_count INTEGER NOT NULL DEFAULT 0,
        connection_count INTEGER NOT NULL DEFAULT 0,
        requested_connections INTEGER NOT NULL DEFAULT 8,
        resume_supported INTEGER,
        server_name TEXT,
        checksum_sha256 TEXT,
        error_code TEXT,
        error_message TEXT,
        source_browser TEXT,
        source_page_url TEXT,
        browser_request_id TEXT,
        description_text TEXT,
        custom_headers_json TEXT,
        average_speed INTEGER NOT NULL DEFAULT 0,
        peak_speed INTEGER NOT NULL DEFAULT 0,
        current_speed INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX idx_downloads_status ON downloads(status);
    CREATE INDEX idx_downloads_filename ON downloads(filename);
    CREATE INDEX idx_downloads_url ON downloads(url);
    CREATE INDEX idx_downloads_category ON downloads(category_id);
    CREATE INDEX idx_downloads_queue ON downloads(queue_id);
    CREATE INDEX idx_downloads_created ON downloads(created_at);
    CREATE TABLE download_segments (
        id TEXT PRIMARY KEY,
        download_id TEXT NOT NULL,
        segment_index INTEGER NOT NULL,
        offset_bytes INTEGER NOT NULL,
        length_bytes INTEGER NOT NULL,
        downloaded INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        speed INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        FOREIGN KEY(download_id) REFERENCES downloads(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_segments_download ON download_segments(download_id);
    CREATE TABLE categories (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        destination TEXT NOT NULL,
        extensions_json TEXT NOT NULL,
        mime_types_json TEXT NOT NULL,
        domain_rules_json TEXT NOT NULL,
        is_enabled INTEGER NOT NULL DEFAULT 1,
        is_built_in INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE queues (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        priority INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 1,
        max_simultaneous INTEGER NOT NULL DEFAULT 3,
        max_connections INTEGER NOT NULL DEFAULT 8,
        bandwidth_limit INTEGER,
        automatic_start INTEGER NOT NULL DEFAULT 1,
        retry_limit INTEGER NOT NULL DEFAULT 5,
        sort_order INTEGER NOT NULL DEFAULT 0,
        schedule_id TEXT
    );
    CREATE TABLE schedules (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        is_enabled INTEGER NOT NULL DEFAULT 1,
        start_hour INTEGER NOT NULL,
        start_minute INTEGER NOT NULL,
        stop_hour INTEGER NOT NULL,
        stop_minute INTEGER NOT NULL,
        days_json TEXT NOT NULL,
        is_recurring INTEGER NOT NULL DEFAULT 1,
        one_shot_date REAL,
        bandwidth_limit INTEGER,
        queue_id TEXT,
        quit_when_done INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value_json TEXT NOT NULL
    );
    CREATE TABLE history (
        id TEXT PRIMARY KEY,
        download_id TEXT,
        url TEXT NOT NULL,
        filename TEXT NOT NULL,
        final_path TEXT,
        size INTEGER,
        status TEXT NOT NULL,
        created_at REAL NOT NULL,
        completed_at REAL
    );
    CREATE INDEX idx_history_created ON history(created_at);
    CREATE TABLE grabber_projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        start_url TEXT NOT NULL,
        scope TEXT NOT NULL,
        types_json TEXT NOT NULL,
        max_depth INTEGER NOT NULL,
        max_urls INTEGER NOT NULL,
        destination TEXT NOT NULL,
        queue_id TEXT,
        created_at REAL NOT NULL,
        status TEXT NOT NULL
    );
    CREATE TABLE grabber_items (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        url TEXT NOT NULL,
        filename TEXT,
        mime_type TEXT,
        selected INTEGER NOT NULL DEFAULT 1,
        status TEXT NOT NULL,
        FOREIGN KEY(project_id) REFERENCES grabber_projects(id) ON DELETE CASCADE
    );
    CREATE TABLE browser_events (
        id TEXT PRIMARY KEY,
        created_at REAL NOT NULL,
        type TEXT NOT NULL,
        url TEXT,
        detail TEXT
    );
    """
}
