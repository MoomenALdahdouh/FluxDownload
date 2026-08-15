import Foundation
import Network
import FluxDownloadCore

public enum TestPayload {
    public static func bytes(count: Int, seed: UInt8 = 0xA5) -> Data {
        Data((0..<count).map { UInt8((Int(seed) + $0) % 256) })
    }
}

public final class TestHTTPServer: @unchecked Sendable {
    public enum Behavior: Sendable {
        case range
        case noRange
        case redirect(String)
        case status(Int)
        case basicAuth(user: String, password: String)
        case slow(TimeInterval)
        case stall
        case dropAfter(Int)
        case chunked
        case html(String)
        case robots(String)
        case playlist(String, contentType: String)
    }

    private let listener: NWListener
    private let payload: Data
    private let queue = DispatchQueue(label: "flux.test.http")
    public private(set) var port: UInt16 = 0
    private var behavior: [String: Behavior]
    public var requireAuth = false
    public var username = "user"
    public var password = "pass"

    public init(payloadSize: Int = 256_000, behavior: [String: Behavior] = [:]) throws {
        self.payload = TestPayload.bytes(count: payloadSize)
        self.behavior = behavior
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener.port?.rawValue {
                        self?.port = port
                    }
                    cont.resume()
                    self?.listener.stateUpdateHandler = { _ in }
                case .failed(let error):
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
    }

    public var origin: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    public func url(_ path: String) -> URL {
        origin.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    public func set(_ path: String, _ value: Behavior) {
        behavior[path] = value
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || (isComplete && (data == nil || data?.isEmpty == true) && !buffer.contains(UInt8(13))) {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let range = next.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = next.subdata(in: next.startIndex..<range.lowerBound)
                let request = String(data: headerData, encoding: .utf8) ?? ""
                self.respond(to: request, connection: connection)
            } else if !isComplete {
                self.receive(on: connection, buffer: next)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to request: String, connection: NWConnection) {
        let lines = request.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = lines.first else {
            connection.cancel()
            return
        }
        let parts = first.split(separator: " ").map(String.init)
        let method = parts.first ?? "GET"
        let pathAndQuery = parts.dropFirst().first ?? "/"
        let path = String(pathAndQuery.split(separator: "?").first ?? "/")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let name = String(line[..<idx]).lowercased()
                let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }

        let route = behavior[path] ?? inferredBehavior(path)
        switch route {
        case .status(let code):
            send(connection, status: code, headers: ["Content-Length": "0"], body: Data())
        case .redirect(let location):
            send(connection, status: 302, headers: ["Location": location, "Content-Length": "0"], body: Data())
        case .basicAuth(let user, let password):
            if !authorized(headers["authorization"], user: user, password: password) {
                send(connection, status: 401, headers: ["WWW-Authenticate": "Basic realm=\"t\"", "Content-Length": "0"], body: Data())
                return
            }
            sendFile(method: method, headers: headers, connection: connection, allowRange: true)
        case .html(let html):
            let body = Data(html.utf8)
            send(connection, status: 200, headers: ["Content-Type": "text/html", "Content-Length": "\(body.count)"], body: body)
        case .robots(let text):
            let body = Data(text.utf8)
            send(connection, status: 200, headers: ["Content-Type": "text/plain", "Content-Length": "\(body.count)"], body: body)
        case .playlist(let text, let contentType):
            let body = Data(text.utf8)
            send(connection, status: 200, headers: ["Content-Type": contentType, "Content-Length": "\(body.count)"], body: body)
        case .stall:
            // Keep the connection open without sending a body.
            send(connection, status: 200, headers: ["Content-Type": "application/octet-stream", "Content-Length": "\(payload.count)"], body: Data(), complete: false)
        case .slow(let delay):
            let captured = headers
            queue.asyncAfter(deadline: .now() + delay) {
                self.sendFile(method: method, headers: captured, connection: connection, allowRange: true)
            }
        case .dropAfter(let count):
            sendFile(method: method, headers: headers, connection: connection, allowRange: true, dropAfter: count)
        case .chunked:
            sendChunked(connection: connection)
        case .noRange:
            sendFile(method: method, headers: headers, connection: connection, allowRange: false)
        case .range:
            sendFile(method: method, headers: headers, connection: connection, allowRange: true)
        }
    }

    private func inferredBehavior(_ path: String) -> Behavior {
        if path.hasSuffix(".m3u8") { return .playlist("#EXTM3U\n", contentType: "application/vnd.apple.mpegurl") }
        if path == "/robots.txt" { return .robots("User-agent: *\nAllow: /\n") }
        if path.contains("norange") { return .noRange }
        return .range
    }

    private func authorized(_ header: String?, user: String, password: String) -> Bool {
        guard let header, header.lowercased().hasPrefix("basic ") else { return false }
        let encoded = String(header.dropFirst(6))
        guard let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) else { return false }
        return decoded == "\(user):\(password)"
    }

    private func sendFile(method: String, headers: [String: String], connection: NWConnection, allowRange: Bool, dropAfter: Int? = nil) {
        if method == "HEAD" {
            var head: [String: String] = [
                "Content-Type": "application/octet-stream",
                "Content-Length": "\(payload.count)"
            ]
            if allowRange { head["Accept-Ranges"] = "bytes" }
            send(connection, status: 200, headers: head, body: Data())
            return
        }
        if allowRange, let range = parseRange(headers["range"]) {
            let start = range.0
            let end = min(range.1, payload.count - 1)
            guard start >= 0, start < payload.count, end >= start else {
                send(connection, status: 416, headers: ["Content-Length": "0"], body: Data())
                return
            }
            var slice = payload.subdata(in: start..<(end + 1))
            if let dropAfter { slice = Data(slice.prefix(dropAfter)) }
            send(
                connection,
                status: 206,
                headers: [
                    "Content-Type": "application/octet-stream",
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes \(start)-\(end)/\(payload.count)",
                    "Content-Length": "\(slice.count)"
                ],
                body: slice
            )
            return
        }
        var body = payload
        if let dropAfter { body = Data(body.prefix(dropAfter)) }
        var head: [String: String] = [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(payload.count)"
        ]
        if allowRange { head["Accept-Ranges"] = "bytes" }
        send(connection, status: 200, headers: head, body: body)
    }

    private func sendChunked(connection: NWConnection) {
        let chunk = payload.prefix(1024)
        var body = Data("\(String(chunk.count, radix: 16))\r\n".utf8)
        body.append(chunk)
        body.append(Data("\r\n0\r\n\r\n".utf8))
        send(
            connection,
            status: 200,
            headers: ["Content-Type": "application/octet-stream", "Transfer-Encoding": "chunked"],
            body: body
        )
    }

    private func parseRange(_ header: String?) -> (Int, Int)? {
        guard let header, header.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst(6)
        let sides = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard sides.count == 2, let start = Int(sides[0]) else { return nil }
        let end = sides[1].isEmpty ? payload.count - 1 : (Int(sides[1]) ?? payload.count - 1)
        return (start, end)
    }

    private func send(_ connection: NWConnection, status: Int, headers: [String: String], body: Data, complete: Bool = true) {
        var text = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        for (key, value) in headers {
            text += "\(key): \(value)\r\n"
        }
        text += "Connection: close\r\n\r\n"
        var data = Data(text.utf8)
        data.append(body)
        connection.send(content: data, contentContext: .defaultMessage, isComplete: complete, completion: .contentProcessed { _ in
            if complete { connection.cancel() }
        })
    }

    private func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 302: return "Found"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
