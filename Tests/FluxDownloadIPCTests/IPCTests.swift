import XCTest
import FluxDownloadCore
import FluxDownloadBrowserProtocol
import FluxDownloadIPC

final class IPCTests: XCTestCase {
    func testRejectsUnauthenticatedAndMalformed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flux-ipc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sock = dir.appendingPathComponent("ipc.sock")
        let server = IPCServer(path: sock, token: "secret") { envelope in
            BrowserResponse(id: envelope.id, ok: true)
        }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        var bad = BrowserEnvelope(type: .ping, payload: .empty)
        bad.token = "nope"
        XCTAssertFalse(try IPCClient.send(bad, path: sock).ok)
        XCTAssertThrowsError(try BrowserMessageValidator.decode(Data(#"{"version":1,"type":"not-a-command","id":"x","payload":{}}"#.utf8)))
    }

    func testPingRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flux-ipc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sock = dir.appendingPathComponent("ipc.sock")
        let server = IPCServer(path: sock, token: "secret") { envelope in
            BrowserResponse(id: envelope.id, ok: envelope.type == .ping)
        }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        var envelope = BrowserEnvelope(type: .ping, payload: .empty)
        envelope.token = "secret"
        XCTAssertTrue(try IPCClient.send(envelope, path: sock).ok)
    }
}
