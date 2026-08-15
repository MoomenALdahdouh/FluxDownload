import Foundation
import FluxDownloadCore
import FluxDownloadBrowserProtocol

public final class IPCServer: @unchecked Sendable {
    private var socketFD: Int32 = -1
    private let path: URL
    private let token: String
    nonisolated(unsafe) public var handler: (BrowserEnvelope) async -> BrowserResponse
    private var running = false

    public init(path: URL = AppPaths.ipcSocket, token: String, handler: @escaping (BrowserEnvelope) async -> BrowserResponse) {
        self.path = path
        self.token = token
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !ownsSocketFile() && Self.isLive(path: path) {
            return
        }
        unlink(path.path)
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw FluxError.configuration("Unable to create IPC socket.") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { pathPtr in
                for (index, value) in bytes.enumerated() where index < 103 {
                    pathPtr[index] = value
                }
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                bind(socketFD, sockAddr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw FluxError.configuration("Unable to bind IPC socket.") }
        chmod(path.path, 0o600)
        guard listen(socketFD, 8) == 0 else { throw FluxError.configuration("Unable to listen on IPC socket.") }
        running = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func restart() throws {
        stop()
        try start()
    }

    public func ownsSocketFile() -> Bool {
        guard socketFD >= 0 else { return false }
        var fdStat = stat()
        var pathStat = stat()
        guard fstat(socketFD, &fdStat) == 0 else { return false }
        guard stat(path.path, &pathStat) == 0 else { return false }
        return fdStat.st_ino == pathStat.st_ino && fdStat.st_dev == pathStat.st_dev
    }

    public static func isLive(path: URL = AppPaths.ipcSocket) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { pathPtr in
                for (index, value) in bytes.enumerated() where index < 103 {
                    pathPtr[index] = value
                }
            }
        }
        let code = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                connect(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return code == 0
    }

    public func stop() {
        running = false
        let owned = ownsSocketFile()
        if socketFD >= 0 { close(socketFD); socketFD = -1 }
        if owned {
            unlink(path.path)
        }
    }

    private func acceptLoop() {
        while running {
            let client = accept(socketFD, nil, nil)
            if client < 0 { continue }
            DispatchQueue.global(qos: .userInitiated).async {
                self.handle(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        guard let data = try? readMessage(from: client) else { return }
        do {
            let envelope = try BrowserMessageValidator.decode(data)
            if envelope.token != token {
                let response = BrowserResponse(id: envelope.id, ok: false, error: FluxError.ipcUnauthenticated.userMessage)
                try writeMessage(BrowserMessageValidator.encode(response), to: client)
                return
            }
            let box = ResponseBox()
            let semaphore = DispatchSemaphore(value: 0)
            let handler = self.handler
            Task.detached {
                let result = await handler(envelope)
                box.set(result)
                semaphore.signal()
            }
            semaphore.wait()
            let response = box.value ?? BrowserResponse(id: envelope.id, ok: false, error: "IPC handler produced no response.")
            try writeMessage(BrowserMessageValidator.encode(response), to: client)
        } catch {
            let response = BrowserResponse(id: "unknown", ok: false, error: FluxError.protocolError("Rejected.").userMessage, diagnostic: "malformed")
            try? writeMessage((try? JSONEncoder().encode(response)) ?? Data(), to: client)
        }
    }
}

public enum IPCClient {
    public static func send(_ envelope: BrowserEnvelope, path: URL = AppPaths.ipcSocket, timeout: TimeInterval = 2) throws -> BrowserResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FluxError.configuration("IPC socket create failed.") }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { pathPtr in
                for (index, value) in bytes.enumerated() where index < 103 {
                    pathPtr[index] = value
                }
            }
        }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let code = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                connect(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if code != 0 { throw FluxError.configuration("Desktop application is not running.") }
        let payload = try JSONEncoder().encode(envelope)
        try writeMessage(payload, to: fd)
        guard let responseData = try readMessage(from: fd) else { throw FluxError.protocolError("Empty IPC response.") }
        return try JSONDecoder().decode(BrowserResponse.self, from: responseData)
    }
}

public enum IPCToken {
    public static func loadOrCreate() throws -> String {
        try AppPaths.ensureSupportDirectories()
        let url = AppPaths.ipcToken
        if let existing = try? String(contentsOf: url, encoding: .utf8), !existing.isEmpty {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let token = UUID().uuidString + UUID().uuidString
        try token.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o600)
        return token
    }
}

func readMessage(from fd: Int32) throws -> Data? {
    var length: UInt32 = 0
    let header = withUnsafeMutableBytes(of: &length) { raw in
        read(fd, raw.baseAddress, 4)
    }
    if header == 0 { return nil }
    guard header == 4 else { throw FluxError.protocolError("Truncated IPC header.") }
    if length > UInt32(BrowserProtocolVersion.maxInboundBytes) { throw FluxError.ipcPayloadTooLarge }
    var data = Data(count: Int(length))
    let got = data.withUnsafeMutableBytes { raw in
        read(fd, raw.baseAddress, Int(length))
    }
    guard got == Int(length) else { throw FluxError.protocolError("Truncated IPC payload.") }
    return data
}

func writeMessage(_ data: Data, to fd: Int32) throws {
    var length = UInt32(data.count)
    _ = withUnsafeBytes(of: &length) { raw in
        write(fd, raw.baseAddress, 4)
    }
    _ = data.withUnsafeBytes { raw in
        write(fd, raw.baseAddress, data.count)
    }
}

final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: BrowserResponse?
    var value: BrowserResponse? {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func set(_ value: BrowserResponse) {
        lock.lock(); storage = value; lock.unlock()
    }
}
