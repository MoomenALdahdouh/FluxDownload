import XCTest
import FluxDownloadCore
@testable import FluxDownloadPersistence

final class PersistenceTests: XCTestCase {
    func testMigrationsAndSeed() async throws {
        let store = try await Store(inMemory: true)
        let settings = try await store.loadSettings()
        XCTAssertEqual(settings.maxConcurrentDownloads, 3)
        let categories = try await store.allCategories()
        XCTAssertTrue(categories.contains(where: { $0.name == "Video" }))
        let queues = try await store.allQueues()
        XCTAssertTrue(queues.contains(where: { $0.name == "Main" }))
    }

    func testCrashSafeDownloadRoundTrip() async throws {
        let store = try await Store(inMemory: true)
        var record = DownloadRecord(
            url: "https://example.com/a.bin",
            filename: "a.bin",
            size: 1024,
            status: .downloading,
            saveDirectory: "/tmp",
            temporaryPath: "/tmp/a.bin.fluxpart"
        )
        try await store.upsertDownload(record)
        let segment = DownloadSegment(downloadID: record.id, index: 0, offset: 0, length: 1024, downloaded: 128, status: .downloading)
        try await store.replaceSegments(downloadID: record.id, segments: [segment])
        record.status = .paused
        record.downloadedBytes = 128
        try await store.upsertDownload(record)
        let loaded = try await store.download(id: record.id)
        XCTAssertEqual(loaded?.status, .paused)
        XCTAssertEqual(loaded?.downloadedBytes, 128)
        let segments = try await store.segments(for: record.id)
        XCTAssertEqual(segments.first?.downloaded, 128)
    }

    func testTransactionRollback() async throws {
        let store = try await Store(inMemory: true)
        do {
            try await store.db.transaction {
                try await store.db.execute("INSERT INTO queues(id, name, priority, is_active, max_simultaneous, max_connections, automatic_start, retry_limit, sort_order) VALUES ('bad','X',0,1,1,1,1,1,1)")
                throw FluxError.database("forced")
            }
        } catch {
            // expected
        }
        let queues = try await store.allQueues()
        XCTAssertFalse(queues.contains(where: { $0.name == "X" }))
    }
}
