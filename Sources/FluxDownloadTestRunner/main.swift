import Foundation
import FluxDownloadCore
import FluxDownloadBrowserProtocol
import FluxDownloadPersistence
import FluxDownloadEngine
import FluxDownloadScheduler
import FluxDownloadMedia
import FluxDownloadGrabber
import FluxDownloadIPC
import FluxDownloadTestServer

@main
enum TestRunner {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passes = 0

    static func expect(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL \(file):\(line) \(message)")
        }
    }

    static func main() async {
        setbuf(stdout, nil)
        print("FluxDownload tests starting")
        coreTests()
        protocolTests()
        mediaTests()
        await persistenceTests()
        await engineTests()
        await grabberTests()
        await ipcTests()
        print("Passed: \(passes)  Failed: \(failures)")
        if failures > 0 { exit(1) }
        print("UNIT/INTEGRATION: PASS")
    }

    static func coreTests() {
        do {
            var status = DownloadStatus.queued
            status = try DownloadStateMachine.transition(from: status, to: .preparing)
            status = try DownloadStateMachine.transition(from: status, to: .connecting)
            status = try DownloadStateMachine.transition(from: status, to: .downloading)
            status = try DownloadStateMachine.transition(from: status, to: .verifying)
            status = try DownloadStateMachine.transition(from: status, to: .completed)
            expect(status == .completed, "happy path")
        } catch {
            expect(false, "happy path threw \(error)")
        }
        expect((try? DownloadStateMachine.transition(from: .completed, to: .downloading)) == nil, "illegal transition")
        expect(FluxError.timeout.isRetryable, "timeout retryable")
        expect(!FluxError.notFound.isRetryable, "404 not retryable")
        expect((try? FilenameSanitizer.sanitize("تقرير.pdf")) == "تقرير.pdf", "arabic")
        expect((try? FilenameSanitizer.sanitize("öğrenci ödevi.zip")) == "öğrenci ödevi.zip", "turkish")
        expect((try? FilenameSanitizer.sanitize("clip 🎬.mp4")) == "clip 🎬.mp4", "emoji")
        expect((try? FilenameSanitizer.sanitize("../etc/passwd")) == nil, "traversal")
        expect((try? FilenameSanitizer.sanitize("/tmp/nested/file.txt")) == "file.txt", "strip path")
        expect((try? URLValidator.parse("https://example.com/a.bin"))?.host == "example.com", "https")
        expect((try? URLValidator.parse("file:///etc/passwd")) == nil, "file scheme")
        let cats = BuiltInCategories.defaults(downloadRoot: URL(fileURLWithPath: "/tmp/dl"))
        expect(BuiltInCategories.assign(filename: "movie.mkv", mimeType: nil, host: nil, categories: cats)?.name == "Video", "video cat")
        let redacted = Redactor.redactHeaders(["Authorization": "Bearer secret", "Accept": "video/mp4"])
        expect(redacted["Authorization"] == "<redacted>", "redact auth")
        let schedule = Schedule(name: "Night", startHour: 22, startMinute: 0, stopHour: 6, stopMinute: 0)
        var components = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 8, day: 15, hour: 23, minute: 0)
        expect(schedule.isActive(at: components.date!), "overnight on")
        components.hour = 12
        expect(!schedule.isActive(at: components.date!), "overnight off")
    }

    static func protocolTests() {
        let json = Data(#"{"version":1,"type":"download.request","id":"abc","payload":{"url":"https://example.com/file.mp4","source":"chrome","capture":true}}"#.utf8)
        do {
            let envelope = try BrowserMessageValidator.decode(json)
            expect(envelope.type == .downloadRequest, "decode type")
        } catch {
            expect(false, "decode failed \(error)")
        }
        expect((try? BrowserMessageValidator.decode(Data(#"{"version":1,"type":"download.request","id":"abc","payload":{"url":"file:///etc/passwd","source":"chrome","capture":false}}"#.utf8))) == nil, "reject file url")
        do {
            let payload = Data(#"{"ok":true}"#.utf8)
            let pipe = Pipe()
            try NativeMessagingCodec.writeMessage(payload, to: pipe.fileHandleForWriting)
            try pipe.fileHandleForWriting.close()
            let read = try NativeMessagingCodec.readMessage(from: pipe.fileHandleForReading)
            expect(read == payload, "native messaging roundtrip")
        } catch {
            expect(false, "codec \(error)")
        }
    }

    static func mediaTests() {
        let hls = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        360.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720
        720.m3u8
        """
        do {
            let group = try HLSParser.parse(hls, base: URL(string: "https://cdn.example/master.m3u8")!)
            expect(group.representations.count == 2, "hls variants")
            expect(group.representations.contains(where: { $0.height == 720 }), "720p")
        } catch {
            expect(false, "hls parse \(error)")
        }
        let protectedHLS = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://license"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720
        720.m3u8
        """
        if let group = try? HLSParser.parse(protectedHLS, base: URL(string: "https://cdn.example/master.m3u8")!) {
            expect(group.isProtected, "protected hls")
            expect(group.visibleRepresentations.isEmpty, "hidden protected")
        } else {
            expect(false, "protected hls parse")
        }
        let dash = """
        <MPD><Representation id="1" bandwidth="800000" width="1280" height="720" codecs="avc1" mimeType="video/mp4"><BaseURL>video.mp4</BaseURL></Representation></MPD>
        """
        expect((try? DASHParser.parse(dash, base: URL(string: "https://cdn.example/manifest.mpd")!))?.representations.first?.height == 720, "dash")
        let protectedDash = """
        <MPD><ContentProtection schemeIdUri="urn:mpeg:cenc:2013"/><Representation id="1" bandwidth="800000" width="1280" height="720" mimeType="video/mp4"></Representation></MPD>
        """
        expect((try? DASHParser.parse(protectedDash, base: URL(string: "https://cdn.example/x.mpd")!)) == nil, "dash drm")
    }

    static func persistenceTests() async {
        do {
            let store = try await Store(inMemory: true)
            let settings = try await store.loadSettings()
            expect(settings.maxConcurrentDownloads == 3, "settings seed")
            let categories = try await store.allCategories()
            expect(categories.contains(where: { $0.name == "Video" }), "categories seed")
            let queues = try await store.allQueues()
            expect(queues.contains(where: { $0.name == "Main" }), "queue seed")
            var record = DownloadRecord(url: "https://example.com/a.bin", filename: "a.bin", size: 1024, status: .downloading, saveDirectory: "/tmp")
            try await store.upsertDownload(record)
            try await store.replaceSegments(downloadID: record.id, segments: [
                DownloadSegment(downloadID: record.id, index: 0, offset: 0, length: 1024, downloaded: 128, status: .downloading)
            ])
            record.status = .paused
            record.downloadedBytes = 128
            try await store.upsertDownload(record)
            let loadedBytes = try await store.download(id: record.id)?.downloadedBytes
            expect(loadedBytes == 128, "persist bytes")
            do {
                try await store.db.transaction {
                    try await store.db.execute("INSERT INTO queues(id, name, priority, is_active, max_simultaneous, max_connections, automatic_start, retry_limit, sort_order) VALUES ('bad','X',0,1,1,1,1,1,1)")
                    throw FluxError.database("forced")
                }
            } catch { }
            let after = try await store.allQueues()
            expect(!after.contains(where: { $0.name == "X" }), "rollback")
        } catch {
            expect(false, "persistence \(error)")
        }
    }

    static func engineTests() async {
        await ranged()
        await noRange()
        await resume()
        await notFound()
        await redirect()
    }

    static func ranged() async {
        do {
            let server = try TestHTTPServer(payloadSize: 256_000, behavior: ["/file.bin": .range])
            try await server.start()
            defer { server.stop() }
            let (store, coordinator, folder) = try await harness()
            defer { try? FileManager.default.removeItem(at: folder) }
            let record = try await coordinator.add(NewDownloadRequest(url: server.url("file.bin"), destination: folder, connections: 4))
            try await wait(store: store, id: record.id, status: .completed)
            let data = try Data(contentsOf: folder.appendingPathComponent("file.bin"))
            expect(data == TestPayload.bytes(count: 256_000), "range payload")
            let loaded = try await store.download(id: record.id)
            expect(loaded?.resumeSupported == true, "range supported")
            expect((loaded?.connectionCount ?? 0) > 1, "multi connection")
        } catch {
            expect(false, "range \(error)")
        }
    }

    static func noRange() async {
        do {
            let server = try TestHTTPServer(payloadSize: 80_000, behavior: ["/plain.bin": .noRange])
            try await server.start()
            defer { server.stop() }
            let (store, coordinator, folder) = try await harness()
            defer { try? FileManager.default.removeItem(at: folder) }
            let record = try await coordinator.add(NewDownloadRequest(url: server.url("plain.bin"), destination: folder, connections: 8))
            try await wait(store: store, id: record.id, status: .completed)
            let plain = try Data(contentsOf: folder.appendingPathComponent("plain.bin"))
            expect(plain == TestPayload.bytes(count: 80_000), "norange payload")
            let count = try await store.download(id: record.id)?.connectionCount
            expect(count == 1, "single connection")
        } catch {
            expect(false, "norange \(error)")
        }
    }

    static func resume() async {
        do {
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
            try await coordinator.start(record.id)
            try await wait(store: store, id: record.id, status: .completed)
            let resumed = try Data(contentsOf: folder.appendingPathComponent("resume.bin"))
            expect(resumed == payload, "resume payload")
        } catch {
            expect(false, "resume \(error)")
        }
    }

    static func notFound() async {
        do {
            let server = try TestHTTPServer(payloadSize: 10, behavior: ["/missing.bin": .status(404)])
            try await server.start()
            defer { server.stop() }
            let (store, coordinator, folder) = try await harness()
            defer { try? FileManager.default.removeItem(at: folder) }
            let record = try await coordinator.add(NewDownloadRequest(url: server.url("missing.bin"), destination: folder))
            try await wait(store: store, id: record.id, status: .failed)
            let failed = try await store.download(id: record.id)?.status
            expect(failed == .failed, "404 failed")
        } catch {
            expect(false, "404 \(error)")
        }
    }

    static func redirect() async {
        do {
            let server = try TestHTTPServer(payloadSize: 32_000, behavior: [
                "/go.bin": .redirect("/target.bin"),
                "/target.bin": .range
            ])
            try await server.start()
            defer { server.stop() }
            let (_, coordinator, folder) = try await harness()
            defer { try? FileManager.default.removeItem(at: folder) }
            _ = try await coordinator.add(NewDownloadRequest(url: server.url("go.bin"), destination: folder, connections: 1))
            let deadline = Date().addingTimeInterval(12)
            var ok = false
            while Date() < deadline {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                for name in files where !name.hasPrefix(".") && !name.contains("sqlite") && !name.hasSuffix(".fluxpart") {
                    if let data = try? Data(contentsOf: folder.appendingPathComponent(name)), data == TestPayload.bytes(count: 32_000) {
                        ok = true
                    }
                }
                if ok { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            expect(ok, "redirect payload")
        } catch {
            expect(false, "redirect \(error)")
        }
    }

    static func grabberTests() async {
        do {
            let html = """
            <html><body>
            <a href="/a.jpg">img</a>
            <a href="/b.mp4">vid</a>
            <a href="/secret/c.pdf">doc</a>
            <a href="https://other.example/x.bin">away</a>
            </body></html>
            """
            let server = try TestHTTPServer(payloadSize: 8, behavior: [
                "/page": .html(html),
                "/robots.txt": .robots("User-agent: *\nDisallow: /secret\n")
            ])
            try await server.start()
            defer { server.stop() }
            let items = try await SiteGrabber().crawl(
                GrabberOptions(
                    startURL: server.origin.appendingPathComponent("page"),
                    scope: .domain,
                    types: [.images, .videos, .documents],
                    maxDepth: 0,
                    delayNanoseconds: 1_000_000
                )
            )
            expect(items.contains(where: { $0.url.contains("a.jpg") }), "grab image")
            expect(items.contains(where: { $0.url.contains("b.mp4") }), "grab video")
            expect(!items.contains(where: { $0.url.contains("secret") }), "robots")
            expect(!items.contains(where: { $0.url.contains("other.example") }), "domain")
        } catch {
            expect(false, "grabber \(error)")
        }
    }

    static func ipcTests() async {
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flux-ipc-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let sock = dir.appendingPathComponent("ipc.sock")
            let server = IPCServer(path: sock, token: "secret") { envelope in
                BrowserResponse(id: envelope.id, ok: envelope.type == .ping)
            }
            try server.start()
            defer { server.stop() }
            try await Task.sleep(nanoseconds: 80_000_000)
            var bad = BrowserEnvelope(type: .ping, payload: .empty)
            bad.token = "nope"
            let unauth = try IPCClient.send(bad, path: sock)
            expect(unauth.ok == false, "unauth")
            var good = BrowserEnvelope(type: .ping, payload: .empty)
            good.token = "secret"
            let ping = try IPCClient.send(good, path: sock)
            expect(ping.ok, "ping")
        } catch {
            expect(false, "ipc \(error)")
        }
    }

    static func harness() async throws -> (Store, DownloadCoordinator, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flux-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try await Store(path: folder.appendingPathComponent("test.sqlite"))
        var settings = AppSettings()
        settings.defaultDownloadFolder = folder.path
        settings.retryLimit = 1
        settings.requestTimeoutSeconds = 8
        return (store, DownloadCoordinator(store: store, settings: settings), folder)
    }

    static func wait(store: Store, id: UUID, status: DownloadStatus, timeout: TimeInterval = 12) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let record = try await store.download(id: id), record.status == status { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let record = try await store.download(id: id)
        throw FluxError.configuration("Timed out waiting for \(status.rawValue), last=\(record?.status.rawValue ?? "nil") \(record?.errorMessage ?? "")")
    }
}
