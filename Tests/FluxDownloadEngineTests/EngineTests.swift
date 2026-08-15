import XCTest
import FluxDownloadCore
import FluxDownloadPersistence
import FluxDownloadEngine
import FluxDownloadTestServer

final class EngineTests: XCTestCase {
    func testRangedDownloadMatchesPayload() async throws {
        let server = try TestHTTPServer(payloadSize: 256_000, behavior: ["/file.bin": .range])
        try await server.start()
        defer { server.stop() }
        let (store, coordinator, folder) = try await harness()
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = try await coordinator.add(NewDownloadRequest(url: server.url("file.bin"), destination: folder, connections: 4))
        try await wait(store: store, id: record.id, status: .completed)
        let data = try Data(contentsOf: folder.appendingPathComponent("file.bin"))
        XCTAssertEqual(data, TestPayload.bytes(count: 256_000))
        let loaded = try await store.download(id: record.id)
        XCTAssertEqual(loaded?.resumeSupported, true)
        XCTAssertGreaterThan(loaded?.connectionCount ?? 0, 1)
    }

    func testNonRangeFallback() async throws {
        let server = try TestHTTPServer(payloadSize: 80_000, behavior: ["/plain.bin": .noRange])
        try await server.start()
        defer { server.stop() }
        let (store, coordinator, folder) = try await harness()
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = try await coordinator.add(NewDownloadRequest(url: server.url("plain.bin"), destination: folder, connections: 8))
        try await wait(store: store, id: record.id, status: .completed)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("plain.bin")), TestPayload.bytes(count: 80_000))
        XCTAssertEqual(try await store.download(id: record.id)?.connectionCount, 1)
    }

    func testInterruptedRangeResumes() async throws {
        let payload = TestPayload.bytes(count: 120_000)
        let server = try TestHTTPServer(payloadSize: 120_000, behavior: ["/resume.bin": .range])
        try await server.start()
        defer { server.stop() }
        let (store, coordinator, folder) = try await harness()
        defer { try? FileManager.default.removeItem(at: folder) }
        var record = DownloadRecord(
            url: server.url("resume.bin").absoluteString,
            filename: "resume.bin",
            size: 120_000,
            downloadedBytes: 40_000,
            status: .paused,
            saveDirectory: folder.path,
            requestedConnections: 1,
            resumeSupported: true
        )
        let temp = folder.appendingPathComponent("resume.bin.fluxpart")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(payload.prefix(40_000)).write(to: temp)
        record.temporaryPath = temp.path
        try await store.upsertDownload(record)
        try await store.replaceSegments(downloadID: record.id, segments: [
            DownloadSegment(downloadID: record.id, index: 0, offset: 0, length: 120_000, downloaded: 40_000, status: .downloading)
        ])
        try await coordinator.start(record.id)
        try await wait(store: store, id: record.id, status: .completed)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("resume.bin")), payload)
    }

    func testHTTP404Fails() async throws {
        let server = try TestHTTPServer(payloadSize: 10, behavior: ["/missing.bin": .status(404)])
        try await server.start()
        defer { server.stop() }
        let (store, coordinator, folder) = try await harness()
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = try await coordinator.add(NewDownloadRequest(url: server.url("missing.bin"), destination: folder))
        try await wait(store: store, id: record.id, status: .failed)
        let loaded = try await store.download(id: record.id)
        XCTAssertEqual(loaded?.status, .failed)
    }

    func testRedirectFollowed() async throws {
        let server = try TestHTTPServer(payloadSize: 32_000, behavior: [
            "/go.bin": .redirect("/target.bin"),
            "/target.bin": .range
        ])
        try await server.start()
        defer { server.stop() }
        let (store, coordinator, folder) = try await harness()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await coordinator.add(NewDownloadRequest(url: server.url("go.bin"), destination: folder, connections: 1))
        try await waitUntilFile(in: folder, size: 32_000)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") && !$0.hasSuffix(".fluxpart") && !$0.hasSuffix(".sqlite") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        XCTAssertFalse(files.isEmpty)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(files[0])), TestPayload.bytes(count: 32_000))
    }
}

private func harness() async throws -> (Store, DownloadCoordinator, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flux-engine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = try await Store(path: folder.appendingPathComponent("test.sqlite"))
    var settings = AppSettings()
    settings.defaultDownloadFolder = folder.path
    settings.retryLimit = 1
    settings.requestTimeoutSeconds = 8
    return (store, DownloadCoordinator(store: store, settings: settings), folder)
}

private func wait(store: Store, id: UUID, status: DownloadStatus, timeout: TimeInterval = 12) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let record = try await store.download(id: id), record.status == status { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let record = try await store.download(id: id)
    throw FluxError.configuration("Timed out waiting for \(status.rawValue), last=\(record?.status.rawValue ?? "nil") \(record?.errorMessage ?? "")")
}

private func waitUntilFile(in folder: URL, size: Int, timeout: TimeInterval = 12) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in files where !name.hasPrefix(".") && !name.contains("sqlite") && !name.hasSuffix(".fluxpart") {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)), data.count == size { return }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw FluxError.timeout
}
