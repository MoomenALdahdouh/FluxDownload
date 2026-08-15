import Foundation
import FluxDownloadCore

public struct RemoteMetadata: Sendable, Equatable {
    public var finalURL: URL
    public var size: Int64?
    public var mimeType: String?
    public var filename: String?
    public var acceptRanges: Bool
    public var server: String?
    public var status: Int

    public init(finalURL: URL, size: Int64?, mimeType: String?, filename: String?, acceptRanges: Bool, server: String?, status: Int) {
        self.finalURL = finalURL
        self.size = size
        self.mimeType = mimeType
        self.filename = filename
        self.acceptRanges = acceptRanges
        self.server = server
        self.status = status
    }
}

public struct ProbeClient: Sendable {
    public var session: URLSession
    public var userAgent: String
    public var extraHeaders: [String: String]

    public init(session: URLSession, userAgent: String = Brand.userAgent, extraHeaders: [String: String] = [:]) {
        self.session = session
        self.userAgent = userAgent
        self.extraHeaders = extraHeaders
    }

    public func probe(url: URL, referrer: String? = nil) async throws -> RemoteMetadata {
        if Task.isCancelled { throw FluxError.cancelled }
        do {
            return try await request(url: url, method: "HEAD", referrer: referrer, range: nil)
        } catch {
            return try await request(url: url, method: "GET", referrer: referrer, range: "bytes=0-0")
        }
    }

    private func request(url: URL, method: String, referrer: String?, range: String?) async throws -> RemoteMetadata {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referrer { request.setValue(referrer, forHTTPHeaderField: "Referer") }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FluxError.networkUnavailable }
        let bodyHead = String(data: data.prefix(64), encoding: .utf8) ?? data.prefix(24).map { String(format: "%02x", $0) }.joined()
        if http.statusCode == 401 || http.statusCode == 403 { throw FluxError.accessDenied }
        if http.statusCode == 404 { throw FluxError.notFound }
        if http.statusCode == 429 { throw FluxError.rateLimited }
        if http.statusCode >= 500 { throw HTTPStatusMapper.error(for: http.statusCode) }
        if !(200...399).contains(http.statusCode) { throw HTTPStatusMapper.error(for: http.statusCode) }

        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, item in
            if let key = item.key as? String { result[key.lowercased()] = String(describing: item.value) }
        }
        let acceptRanges: Bool
        if http.statusCode == 206 { acceptRanges = true }
        else { acceptRanges = (headers["accept-ranges"] ?? "").lowercased().contains("bytes") }

        var size: Int64?
        if let length = headers["content-length"], let value = Int64(length), http.statusCode != 206 {
            size = value
        }
        if let contentRange = headers["content-range"], let total = contentRange.split(separator: "/").last, let value = Int64(total) {
            size = value
        }
        try Self.rejectFakeMedia(
            url: url,
            mime: headers["content-type"],
            size: size,
            bodyHead: bodyHead
        )
        let filename = try? FilenameSanitizer.fromContentDisposition(headers["content-disposition"])
        let finalURL = http.url ?? url
        return RemoteMetadata(
            finalURL: finalURL,
            size: size,
            mimeType: headers["content-type"],
            filename: filename,
            acceptRanges: acceptRanges,
            server: headers["server"],
            status: http.statusCode
        )
    }

    static func rejectFakeMedia(url: URL, mime: String?, size: Int64?, bodyHead: String) throws {
        let lower = (mime ?? "").lowercased()
        let host = url.host?.lowercased() ?? ""
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let sabr = items.contains { $0.name == "sabr" && $0.value == "1" }
        let itag = items.contains { $0.name == "itag" && !($0.value ?? "").isEmpty }
        let fake = lower.contains("yt-ump")
            || lower.contains("vnd.yt")
            || bodyHead.contains("sabr.")
            || sabr
            || (host.contains("googlevideo") && !itag)
            || (lower.hasPrefix("video/") && (size ?? 0) > 0 && (size ?? 0) < 8192)
        if fake { throw FluxError.unsupportedMedia }
    }
}
