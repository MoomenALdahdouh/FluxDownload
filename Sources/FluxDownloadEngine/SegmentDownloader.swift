import Foundation
import FluxDownloadCore

public final class ChunkedTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let onChunk: @Sendable (Data) throws -> Void
    private var finish: CheckedContinuation<HTTPURLResponse, Error>?
    private var httpResponse: HTTPURLResponse?
    private var failed: Error?
    private let lock = NSLock()

    public init(onChunk: @escaping @Sendable (Data) throws -> Void) {
        self.onChunk = onChunk
    }

    public func run(session: URLSession, request: URLRequest) async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            finish = continuation
            lock.unlock()
            let task = session.dataTask(with: request)
            task.delegate = self
            task.resume()
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            httpResponse = http
            completionHandler(.allow)
        } else {
            completionHandler(.cancel)
            resume(throwing: FluxError.networkUnavailable)
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try onChunk(data)
        } catch {
            failed = error
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failed {
            resume(throwing: failed)
            return
        }
        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                resume(throwing: CancellationError())
                return
            }
            resume(throwing: error)
            return
        }
        if let httpResponse {
            resume(returning: httpResponse)
        } else {
            resume(throwing: FluxError.connectionReset)
        }
    }

    private func resume(throwing error: Error) {
        lock.lock()
        let cont = finish
        finish = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }

    private func resume(returning value: HTTPURLResponse) {
        lock.lock()
        let cont = finish
        finish = nil
        lock.unlock()
        cont?.resume(returning: value)
    }
}

public struct SegmentDownloader: Sendable {
    public var session: URLSession
    public var userAgent: String
    public var timeout: TimeInterval

    public init(session: URLSession, userAgent: String, timeout: TimeInterval, stallTimeout: TimeInterval = 20) {
        self.session = session
        self.userAgent = userAgent
        self.timeout = timeout
        _ = stallTimeout
    }

    public func download(
        url: URL,
        offset: Int64,
        length: Int64?,
        resumeFrom: Int64,
        referrer: String?,
        headers: [String: String],
        fd: Int32,
        shouldCancel: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        httpRange: (start: Int64, end: Int64)? = nil
    ) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referrer { request.setValue(referrer, forHTTPHeaderField: "Referer") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let start = offset + resumeFrom
        if let httpRange {
            request.setValue("bytes=\(httpRange.start)-\(httpRange.end)", forHTTPHeaderField: "Range")
        } else if let length {
            let end = offset + length - 1
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        } else if resumeFrom > 0 {
            request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
        }

        let written = LockedCounter(resumeFrom)
        let lastTick = LockedDate()
        let window = LockedCounter(0)

        let transfer = ChunkedTransfer { data in
            if shouldCancel() { throw CancellationError() }
            let at = offset + written.value
            try PartialFile.write(fd: fd, data: data, offset: at)
            let total = written.add(Int64(data.count))
            let windowNow = window.add(Int64(data.count))
            let elapsed = lastTick.elapsed()
            if elapsed >= 0.25 {
                let speed = Int64(Double(windowNow) / elapsed)
                window.reset()
                lastTick.reset()
                onProgress(total, speed)
            }
        }

        let response = try await transfer.run(session: session, request: request)
        if !HTTPStatusMapper.isSuccess(response.statusCode) {
            throw HTTPStatusMapper.error(for: response.statusCode)
        }
        if resumeFrom > 0 && response.statusCode == 200 && offset > 0 {
            throw FluxError.resumeUnavailable
        }
        onProgress(written.value, 0)
        return written.value
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int64
    init(_ value: Int64) { storage = value }
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return storage }
    @discardableResult func add(_ delta: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        storage += delta
        return storage
    }
    func reset() { lock.lock(); storage = 0; lock.unlock() }
}

final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Date()
    func elapsed() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(storage)
    }
    func reset() { lock.lock(); storage = Date(); lock.unlock() }
}
