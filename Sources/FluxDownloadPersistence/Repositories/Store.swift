import Foundation
import FluxDownloadCore

public actor Store {
    public let db: DatabaseActor

    public init(path: URL) async throws {
        db = try await DatabaseActor(path: path)
        try await Migrations.apply(on: db)
        try await seedIfNeeded()
    }

    public init(inMemory: Bool) async throws {
        let path: URL
        if inMemory {
            path = FileManager.default.temporaryDirectory.appendingPathComponent("flux-\(UUID().uuidString).sqlite")
        } else {
            path = AppPaths.databaseFile
        }
        try await self.init(path: path)
    }

    private func seedIfNeeded() async throws {
        let queueCount = try await db.query("SELECT COUNT(*) AS c FROM queues")
        if queueCount.first?["c"]?.int64 == 0 {
            try await upsertQueue(DownloadQueue.mainDefault())
        }
        let categoryCount = try await db.query("SELECT COUNT(*) AS c FROM categories")
        if categoryCount.first?["c"]?.int64 == 0 {
            let root = AppPaths.defaultDownloadDirectory
            for category in BuiltInCategories.defaults(downloadRoot: root) {
                try await upsertCategory(category)
            }
        }
        let settingsCount = try await db.query("SELECT COUNT(*) AS c FROM settings WHERE key='app'")
        if settingsCount.first?["c"]?.int64 == 0 {
            try await saveSettings(AppSettings())
        }
    }

    public func saveSettings(_ settings: AppSettings) async throws {
        let data = try JSONEncoder().encode(settings)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try await db.execute(
            "INSERT INTO settings(key, value_json) VALUES('app', ?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json",
            binds: [.text(json)]
        )
    }

    public func loadSettings() async throws -> AppSettings {
        let rows = try await db.query("SELECT value_json FROM settings WHERE key='app'")
        guard let json = rows.first?["value_json"]?.string, let data = json.data(using: .utf8) else {
            return AppSettings()
        }
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }

    public func upsertDownload(_ record: DownloadRecord) async throws {
        try await db.execute(
            """
            INSERT INTO downloads (
                id, url, original_url, final_url, filename, file_extension, mime_type, size, downloaded_bytes, status,
                category_id, queue_id, priority, created_at, started_at, completed_at, save_directory, temporary_path,
                final_path, referrer, user_agent, credential_ref, cookie_ref, retry_count, connection_count,
                requested_connections, resume_supported, server_name, checksum_sha256, error_code, error_message,
                source_browser, source_page_url, browser_request_id, description_text, custom_headers_json,
                average_speed, peak_speed, current_speed
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                url=excluded.url, original_url=excluded.original_url, final_url=excluded.final_url,
                filename=excluded.filename, file_extension=excluded.file_extension, mime_type=excluded.mime_type,
                size=excluded.size, downloaded_bytes=excluded.downloaded_bytes, status=excluded.status,
                category_id=excluded.category_id, queue_id=excluded.queue_id, priority=excluded.priority,
                started_at=excluded.started_at, completed_at=excluded.completed_at, save_directory=excluded.save_directory,
                temporary_path=excluded.temporary_path, final_path=excluded.final_path, referrer=excluded.referrer,
                user_agent=excluded.user_agent, credential_ref=excluded.credential_ref, cookie_ref=excluded.cookie_ref,
                retry_count=excluded.retry_count, connection_count=excluded.connection_count,
                requested_connections=excluded.requested_connections, resume_supported=excluded.resume_supported,
                server_name=excluded.server_name, checksum_sha256=excluded.checksum_sha256, error_code=excluded.error_code,
                error_message=excluded.error_message, source_browser=excluded.source_browser,
                source_page_url=excluded.source_page_url, browser_request_id=excluded.browser_request_id,
                description_text=excluded.description_text, custom_headers_json=excluded.custom_headers_json,
                average_speed=excluded.average_speed, peak_speed=excluded.peak_speed, current_speed=excluded.current_speed
            """,
            binds: downloadBinds(record)
        )
    }

    public func download(id: UUID) async throws -> DownloadRecord? {
        let rows = try await db.query("SELECT * FROM downloads WHERE id=?", binds: [.text(id.uuidString)])
        return rows.first.flatMap(Self.record(from:))
    }

    public func allDownloads(includingRemoved: Bool = false) async throws -> [DownloadRecord] {
        let sql = includingRemoved
            ? "SELECT * FROM downloads ORDER BY created_at DESC"
            : "SELECT * FROM downloads WHERE status != 'removed' ORDER BY created_at DESC"
        return try await db.query(sql).compactMap(Self.record(from:))
    }

    public func downloads(matching query: String) async throws -> [DownloadRecord] {
        let like = "%\(query.lowercased())%"
        return try await db.query(
            """
            SELECT * FROM downloads
            WHERE status != 'removed' AND (
                lower(filename) LIKE ? OR lower(url) LIKE ? OR lower(IFNULL(description_text,'')) LIKE ?
                OR lower(IFNULL(source_page_url,'')) LIKE ?
            )
            ORDER BY created_at DESC
            """,
            binds: [.text(like), .text(like), .text(like), .text(like)]
        ).compactMap(Self.record(from:))
    }

    public func activeDownloads() async throws -> [DownloadRecord] {
        try await db.query(
            "SELECT * FROM downloads WHERE status IN ('queued','preparing','connecting','downloading','paused','stalled','retrying','verifying')"
        ).compactMap(Self.record(from:))
    }

    public func findDuplicate(normalizedURL: String, browserRequestID: String?) async throws -> DownloadRecord? {
        if let browserRequestID {
            let rows = try await db.query(
                "SELECT * FROM downloads WHERE browser_request_id=? AND status != 'removed' LIMIT 1",
                binds: [.text(browserRequestID)]
            )
            if let row = rows.first { return Self.record(from: row) }
        }
        let rows = try await db.query(
            "SELECT * FROM downloads WHERE url=? AND status IN ('queued','preparing','connecting','downloading','paused','stalled','retrying','verifying') LIMIT 1",
            binds: [.text(normalizedURL)]
        )
        return rows.first.flatMap(Self.record(from:))
    }

    public func deleteDownload(id: UUID) async throws {
        try await db.execute("DELETE FROM download_segments WHERE download_id=?", binds: [.text(id.uuidString)])
        try await db.execute("DELETE FROM downloads WHERE id=?", binds: [.text(id.uuidString)])
    }

    public func replaceSegments(downloadID: UUID, segments: [DownloadSegment]) async throws {
        try await db.execute("DELETE FROM download_segments WHERE download_id=?", binds: [.text(downloadID.uuidString)])
        for segment in segments {
            try await upsertSegment(segment)
        }
    }

    public func upsertSegment(_ segment: DownloadSegment) async throws {
        try await db.execute(
            """
            INSERT INTO download_segments(id, download_id, segment_index, offset_bytes, length_bytes, downloaded, status, speed, last_error)
            VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET downloaded=excluded.downloaded, status=excluded.status, speed=excluded.speed, last_error=excluded.last_error
            """,
            binds: [
                .text(segment.id.uuidString),
                .text(segment.downloadID.uuidString),
                .int(Int64(segment.index)),
                .int(segment.offset),
                .int(segment.length),
                .int(segment.downloaded),
                .text(segment.status.rawValue),
                .int(segment.speed),
                segment.lastError.map { .text($0) } ?? .null
            ]
        )
    }

    public func segments(for downloadID: UUID) async throws -> [DownloadSegment] {
        try await db.query(
            "SELECT * FROM download_segments WHERE download_id=? ORDER BY segment_index ASC",
            binds: [.text(downloadID.uuidString)]
        ).compactMap(Self.segment(from:))
    }

    public func upsertCategory(_ category: FileCategory) async throws {
        try await db.execute(
            """
            INSERT INTO categories(id, name, destination, extensions_json, mime_types_json, domain_rules_json, is_enabled, is_built_in, sort_order)
            VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, destination=excluded.destination, extensions_json=excluded.extensions_json,
                mime_types_json=excluded.mime_types_json, domain_rules_json=excluded.domain_rules_json, is_enabled=excluded.is_enabled, sort_order=excluded.sort_order
            """,
            binds: [
                .text(category.id.uuidString),
                .text(category.name),
                .text(category.destination),
                .text(Self.encode(category.extensions)),
                .text(Self.encode(category.mimeTypes)),
                .text(Self.encode(category.domainRules)),
                .int(category.isEnabled ? 1 : 0),
                .int(category.isBuiltIn ? 1 : 0),
                .int(Int64(category.sortOrder))
            ]
        )
    }

    public func allCategories() async throws -> [FileCategory] {
        try await db.query("SELECT * FROM categories ORDER BY sort_order ASC").compactMap(Self.category(from:))
    }

    public func deleteCategory(id: UUID) async throws {
        try await db.execute("DELETE FROM categories WHERE id=? AND is_built_in=0", binds: [.text(id.uuidString)])
    }

    public func upsertQueue(_ queue: DownloadQueue) async throws {
        try await db.execute(
            """
            INSERT INTO queues(id, name, priority, is_active, max_simultaneous, max_connections, bandwidth_limit, automatic_start, retry_limit, sort_order, schedule_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, priority=excluded.priority, is_active=excluded.is_active,
                max_simultaneous=excluded.max_simultaneous, max_connections=excluded.max_connections, bandwidth_limit=excluded.bandwidth_limit,
                automatic_start=excluded.automatic_start, retry_limit=excluded.retry_limit, sort_order=excluded.sort_order, schedule_id=excluded.schedule_id
            """,
            binds: [
                .text(queue.id.uuidString),
                .text(queue.name),
                .int(Int64(queue.priority)),
                .int(queue.isActive ? 1 : 0),
                .int(Int64(queue.maxSimultaneousDownloads)),
                .int(Int64(queue.maxConnectionsPerDownload)),
                queue.bandwidthLimitBytesPerSecond.map { .int($0) } ?? .null,
                .int(queue.automaticStart ? 1 : 0),
                .int(Int64(queue.retryLimit)),
                .int(Int64(queue.sortOrder)),
                queue.scheduleID.map { .text($0.uuidString) } ?? .null
            ]
        )
    }

    public func allQueues() async throws -> [DownloadQueue] {
        try await db.query("SELECT * FROM queues ORDER BY sort_order ASC").compactMap(Self.queue(from:))
    }

    public func deleteQueue(id: UUID) async throws {
        try await db.execute("DELETE FROM queues WHERE id=?", binds: [.text(id.uuidString)])
    }

    public func upsertSchedule(_ schedule: Schedule) async throws {
        try await db.execute(
            """
            INSERT INTO schedules(id, name, is_enabled, start_hour, start_minute, stop_hour, stop_minute, days_json, is_recurring, one_shot_date, bandwidth_limit, queue_id, quit_when_done)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, is_enabled=excluded.is_enabled, start_hour=excluded.start_hour,
                start_minute=excluded.start_minute, stop_hour=excluded.stop_hour, stop_minute=excluded.stop_minute,
                days_json=excluded.days_json, is_recurring=excluded.is_recurring, one_shot_date=excluded.one_shot_date,
                bandwidth_limit=excluded.bandwidth_limit, queue_id=excluded.queue_id, quit_when_done=excluded.quit_when_done
            """,
            binds: [
                .text(schedule.id.uuidString),
                .text(schedule.name),
                .int(schedule.isEnabled ? 1 : 0),
                .int(Int64(schedule.startHour)),
                .int(Int64(schedule.startMinute)),
                .int(Int64(schedule.stopHour)),
                .int(Int64(schedule.stopMinute)),
                .text(Self.encode(schedule.days.map(\.rawValue))),
                .int(schedule.isRecurring ? 1 : 0),
                schedule.oneShotDate.map { .double($0.timeIntervalSince1970) } ?? .null,
                schedule.bandwidthLimitBytesPerSecond.map { .int($0) } ?? .null,
                schedule.queueID.map { .text($0.uuidString) } ?? .null,
                .int(schedule.quitWhenDone ? 1 : 0)
            ]
        )
    }

    public func allSchedules() async throws -> [Schedule] {
        try await db.query("SELECT * FROM schedules ORDER BY name ASC").compactMap(Self.schedule(from:))
    }

    public func deleteSchedule(id: UUID) async throws {
        try await db.execute("DELETE FROM schedules WHERE id=?", binds: [.text(id.uuidString)])
    }

    public func insertHistory(from record: DownloadRecord) async throws {
        try await db.execute(
            """
            INSERT INTO history(id, download_id, url, filename, final_path, size, status, created_at, completed_at)
            VALUES (?,?,?,?,?,?,?,?,?)
            """,
            binds: [
                .text(UUID().uuidString),
                .text(record.id.uuidString),
                .text(record.url),
                .text(record.filename),
                record.finalPath.map { .text($0) } ?? .null,
                record.size.map { .int($0) } ?? .null,
                .text(record.status.rawValue),
                .double(record.createdAt.timeIntervalSince1970),
                record.completedAt.map { .double($0.timeIntervalSince1970) } ?? .null
            ]
        )
    }

    public func allHistory() async throws -> [DownloadRecord] {
        try await db.query("SELECT * FROM history ORDER BY created_at DESC").compactMap { row in
            guard let url = row["url"]?.string, let filename = row["filename"]?.string else { return nil }
            return DownloadRecord(
                id: UUID(uuidString: row["download_id"]?.string ?? "") ?? UUID(),
                url: url,
                filename: filename,
                size: row["size"]?.int64,
                status: DownloadStatus(rawValue: row["status"]?.string ?? "") ?? .completed,
                createdAt: Date(timeIntervalSince1970: row["created_at"]?.doubleValue ?? 0),
                completedAt: row["completed_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
                saveDirectory: "",
                finalPath: row["final_path"]?.string
            )
        }
    }

    public func clearHistory() async throws {
        try await db.execute("DELETE FROM history")
    }

    public func insertBrowserEvent(type: String, url: String?, detail: String?) async throws {
        try await db.execute(
            "INSERT INTO browser_events(id, created_at, type, url, detail) VALUES (?,?,?,?,?)",
            binds: [
                .text(UUID().uuidString),
                .double(Date().timeIntervalSince1970),
                .text(type),
                url.map { .text($0) } ?? .null,
                detail.map { .text($0) } ?? .null
            ]
        )
    }

    public func upsertGrabberProject(_ project: GrabberProject) async throws {
        try await db.execute(
            """
            INSERT INTO grabber_projects(id, name, start_url, scope, types_json, max_depth, max_urls, destination, queue_id, created_at, status)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, status=excluded.status
            """,
            binds: [
                .text(project.id.uuidString),
                .text(project.name),
                .text(project.startURL),
                .text(project.scope.rawValue),
                .text(Self.encode(project.resourceTypes.map(\.rawValue))),
                .int(Int64(project.maxDepth)),
                .int(Int64(project.maxURLs)),
                .text(project.destination),
                project.queueID.map { .text($0.uuidString) } ?? .null,
                .double(project.createdAt.timeIntervalSince1970),
                .text(project.status)
            ]
        )
        try await db.execute("DELETE FROM grabber_items WHERE project_id=?", binds: [.text(project.id.uuidString)])
        for item in project.items {
            try await db.execute(
                "INSERT INTO grabber_items(id, project_id, url, filename, mime_type, selected, status) VALUES (?,?,?,?,?,?,?)",
                binds: [
                    .text(item.id.uuidString),
                    .text(project.id.uuidString),
                    .text(item.url),
                    item.filename.map { .text($0) } ?? .null,
                    item.mimeType.map { .text($0) } ?? .null,
                    .int(item.selected ? 1 : 0),
                    .text(item.status)
                ]
            )
        }
    }

    public func allGrabberProjects() async throws -> [GrabberProject] {
        let rows = try await db.query("SELECT * FROM grabber_projects ORDER BY created_at DESC")
        var projects: [GrabberProject] = []
        for row in rows {
            guard var project = Self.project(from: row) else { continue }
            let items = try await db.query("SELECT * FROM grabber_items WHERE project_id=?", binds: [.text(project.id.uuidString)])
            project.items = items.compactMap(Self.grabberItem(from:))
            projects.append(project)
        }
        return projects
    }

    public func exportConfiguration() async throws -> Data {
        let payload = ConfigurationExport(
            settings: try await loadSettings(),
            categories: try await allCategories(),
            queues: try await allQueues(),
            schedules: try await allSchedules()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    public func importConfiguration(_ data: Data) async throws {
        let payload = try JSONDecoder().decode(ConfigurationExport.self, from: data)
        var settings = payload.settings
        settings.proxyCredentialRef = nil
        try await saveSettings(settings)
        for category in payload.categories { try await upsertCategory(category) }
        for queue in payload.queues { try await upsertQueue(queue) }
        for schedule in payload.schedules { try await upsertSchedule(schedule) }
    }

    private func downloadBinds(_ record: DownloadRecord) -> [SQLValue] {
        [
            .text(record.id.uuidString),
            .text(record.url),
            .text(record.originalURL),
            record.finalURL.map { .text($0) } ?? .null,
            .text(record.filename),
            .text(record.fileExtension),
            record.mimeType.map { .text($0) } ?? .null,
            record.size.map { .int($0) } ?? .null,
            .int(record.downloadedBytes),
            .text(record.status.rawValue),
            record.categoryID.map { .text($0.uuidString) } ?? .null,
            record.queueID.map { .text($0.uuidString) } ?? .null,
            .int(Int64(record.priority.rawValue)),
            .double(record.createdAt.timeIntervalSince1970),
            record.startedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            record.completedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            .text(record.saveDirectory),
            record.temporaryPath.map { .text($0) } ?? .null,
            record.finalPath.map { .text($0) } ?? .null,
            record.referrer.map { .text($0) } ?? .null,
            record.userAgent.map { .text($0) } ?? .null,
            record.credentialRef.map { .text($0) } ?? .null,
            record.cookieRef.map { .text($0) } ?? .null,
            .int(Int64(record.retryCount)),
            .int(Int64(record.connectionCount)),
            .int(Int64(record.requestedConnections)),
            record.resumeSupported.map { .int($0 ? 1 : 0) } ?? .null,
            record.serverName.map { .text($0) } ?? .null,
            record.checksumSHA256.map { .text($0) } ?? .null,
            record.errorCode.map { .text($0) } ?? .null,
            record.errorMessage.map { .text($0) } ?? .null,
            record.sourceBrowser.map { .text($0) } ?? .null,
            record.sourcePageURL.map { .text($0) } ?? .null,
            record.browserRequestID.map { .text($0) } ?? .null,
            record.descriptionText.map { .text($0) } ?? .null,
            record.customHeadersJSON.map { .text($0) } ?? .null,
            .int(record.averageSpeed),
            .int(record.peakSpeed),
            .int(record.currentSpeed)
        ]
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func decodeStringArray(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func record(from row: [String: SQLValue]) -> DownloadRecord? {
        guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
              let url = row["url"]?.string,
              let filename = row["filename"]?.string,
              let statusRaw = row["status"]?.string,
              let status = DownloadStatus(rawValue: statusRaw),
              let saveDirectory = row["save_directory"]?.string else { return nil }
        return DownloadRecord(
            id: id,
            url: url,
            originalURL: row["original_url"]?.string ?? url,
            finalURL: row["final_url"]?.string,
            filename: filename,
            fileExtension: row["file_extension"]?.string ?? "",
            mimeType: row["mime_type"]?.string,
            size: row["size"]?.int64,
            downloadedBytes: row["downloaded_bytes"]?.int64 ?? 0,
            status: status,
            categoryID: row["category_id"]?.string.flatMap(UUID.init(uuidString:)),
            queueID: row["queue_id"]?.string.flatMap(UUID.init(uuidString:)),
            priority: DownloadPriority(rawValue: Int(row["priority"]?.int64 ?? 1)) ?? .normal,
            createdAt: Date(timeIntervalSince1970: row["created_at"]?.doubleValue ?? 0),
            startedAt: row["started_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            completedAt: row["completed_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            saveDirectory: saveDirectory,
            temporaryPath: row["temporary_path"]?.string,
            finalPath: row["final_path"]?.string,
            referrer: row["referrer"]?.string,
            userAgent: row["user_agent"]?.string,
            credentialRef: row["credential_ref"]?.string,
            cookieRef: row["cookie_ref"]?.string,
            retryCount: Int(row["retry_count"]?.int64 ?? 0),
            connectionCount: Int(row["connection_count"]?.int64 ?? 0),
            requestedConnections: Int(row["requested_connections"]?.int64 ?? 8),
            resumeSupported: row["resume_supported"]?.int64.map { $0 != 0 },
            serverName: row["server_name"]?.string,
            checksumSHA256: row["checksum_sha256"]?.string,
            errorCode: row["error_code"]?.string,
            errorMessage: row["error_message"]?.string,
            sourceBrowser: row["source_browser"]?.string,
            sourcePageURL: row["source_page_url"]?.string,
            browserRequestID: row["browser_request_id"]?.string,
            descriptionText: row["description_text"]?.string,
            customHeadersJSON: row["custom_headers_json"]?.string,
            averageSpeed: row["average_speed"]?.int64 ?? 0,
            peakSpeed: row["peak_speed"]?.int64 ?? 0,
            currentSpeed: row["current_speed"]?.int64 ?? 0
        )
    }

    private static func segment(from row: [String: SQLValue]) -> DownloadSegment? {
        guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
              let downloadID = row["download_id"]?.string.flatMap(UUID.init(uuidString:)),
              let status = row["status"]?.string.flatMap(SegmentStatus.init(rawValue:)) else { return nil }
        return DownloadSegment(
            id: id,
            downloadID: downloadID,
            index: Int(row["segment_index"]?.int64 ?? 0),
            offset: row["offset_bytes"]?.int64 ?? 0,
            length: row["length_bytes"]?.int64 ?? 0,
            downloaded: row["downloaded"]?.int64 ?? 0,
            status: status,
            speed: row["speed"]?.int64 ?? 0,
            lastError: row["last_error"]?.string
        )
    }

    private static func category(from row: [String: SQLValue]) -> FileCategory? {
        guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
              let name = row["name"]?.string,
              let destination = row["destination"]?.string else { return nil }
        return FileCategory(
            id: id,
            name: name,
            destination: destination,
            extensions: decodeStringArray(row["extensions_json"]?.string),
            mimeTypes: decodeStringArray(row["mime_types_json"]?.string),
            domainRules: decodeStringArray(row["domain_rules_json"]?.string),
            isEnabled: (row["is_enabled"]?.int64 ?? 1) != 0,
            isBuiltIn: (row["is_built_in"]?.int64 ?? 0) != 0,
            sortOrder: Int(row["sort_order"]?.int64 ?? 0)
        )
    }

    private static func queue(from row: [String: SQLValue]) -> DownloadQueue? {
        guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
              let name = row["name"]?.string else { return nil }
        return DownloadQueue(
            id: id,
            name: name,
            priority: Int(row["priority"]?.int64 ?? 0),
            isActive: (row["is_active"]?.int64 ?? 1) != 0,
            maxSimultaneousDownloads: Int(row["max_simultaneous"]?.int64 ?? 3),
            maxConnectionsPerDownload: Int(row["max_connections"]?.int64 ?? 8),
            bandwidthLimitBytesPerSecond: row["bandwidth_limit"]?.int64,
            automaticStart: (row["automatic_start"]?.int64 ?? 1) != 0,
            retryLimit: Int(row["retry_limit"]?.int64 ?? 5),
            sortOrder: Int(row["sort_order"]?.int64 ?? 0),
            scheduleID: row["schedule_id"]?.string.flatMap(UUID.init(uuidString:))
        )
    }

    private static func schedule(from row: [String: SQLValue]) -> Schedule? {
        guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
              let name = row["name"]?.string else { return nil }
        let days = (decodeStringArray(row["days_json"]?.string).compactMap { Int($0) }.compactMap(Weekday.init(rawValue:)))
        let decodedInts = (try? JSONDecoder().decode([Int].self, from: Data((row["days_json"]?.string ?? "[]").utf8))) ?? []
        let weekdays = decodedInts.compactMap(Weekday.init(rawValue:))
        return Schedule(
            id: id,
            name: name,
            isEnabled: (row["is_enabled"]?.int64 ?? 1) != 0,
            startHour: Int(row["start_hour"]?.int64 ?? 0),
            startMinute: Int(row["start_minute"]?.int64 ?? 0),
            stopHour: Int(row["stop_hour"]?.int64 ?? 23),
            stopMinute: Int(row["stop_minute"]?.int64 ?? 59),
            days: weekdays.isEmpty ? days : weekdays,
            isRecurring: (row["is_recurring"]?.int64 ?? 1) != 0,
            oneShotDate: row["one_shot_date"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            bandwidthLimitBytesPerSecond: row["bandwidth_limit"]?.int64,
            queueID: row["queue_id"]?.string.flatMap(UUID.init(uuidString:)),
            quitWhenDone: (row["quit_when_done"]?.int64 ?? 0) != 0
        )
    }

    private static func project(from row: [String: SQLValue]) -> GrabberProject? {
        guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
              let name = row["name"]?.string,
              let startURL = row["start_url"]?.string,
              let scopeRaw = row["scope"]?.string,
              let scope = GrabberScope(rawValue: scopeRaw) else { return nil }
        let types = decodeStringArray(row["types_json"]?.string).compactMap(GrabberResourceType.init(rawValue:))
        return GrabberProject(
            id: id,
            name: name,
            startURL: startURL,
            scope: scope,
            resourceTypes: types,
            maxDepth: Int(row["max_depth"]?.int64 ?? 1),
            maxURLs: Int(row["max_urls"]?.int64 ?? 200),
            destination: row["destination"]?.string ?? "",
            queueID: row["queue_id"]?.string.flatMap(UUID.init(uuidString:)),
            createdAt: Date(timeIntervalSince1970: row["created_at"]?.doubleValue ?? 0),
            status: row["status"]?.string ?? "idle",
            items: []
        )
    }

    private static func grabberItem(from row: [String: SQLValue]) -> GrabberItem? {
        guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
              let url = row["url"]?.string else { return nil }
        return GrabberItem(
            id: id,
            url: url,
            filename: row["filename"]?.string,
            mimeType: row["mime_type"]?.string,
            selected: (row["selected"]?.int64 ?? 1) != 0,
            status: row["status"]?.string ?? "found"
        )
    }
}

public struct ConfigurationExport: Codable, Sendable {
    public var settings: AppSettings
    public var categories: [FileCategory]
    public var queues: [DownloadQueue]
    public var schedules: [Schedule]
}
