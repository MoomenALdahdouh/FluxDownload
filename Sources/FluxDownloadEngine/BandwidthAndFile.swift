import Foundation
import FluxDownloadCore

public actor BandwidthManager {
    public var globalLimit: Int64?
    public var queueLimits: [UUID: Int64] = [:]
    private var windowStart = Date()
    private var windowBytes: Int64 = 0

    public init(globalLimit: Int64? = nil) {
        self.globalLimit = globalLimit
    }

    public func setGlobalLimit(_ limit: Int64?) {
        globalLimit = limit
    }

    public func setQueueLimit(_ queueID: UUID, _ limit: Int64?) {
        queueLimits[queueID] = limit
    }

    public func consume(bytes: Int, queueID: UUID?) async {
        let limit = effectiveLimit(queueID: queueID)
        guard let limit, limit > 0 else { return }
        let now = Date()
        if now.timeIntervalSince(windowStart) >= 1 {
            windowStart = now
            windowBytes = 0
        }
        windowBytes += Int64(bytes)
        if windowBytes > limit {
            let overflow = Double(windowBytes - limit)
            let delay = overflow / Double(limit)
            windowStart = Date()
            windowBytes = 0
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(delay, 2) * 1_000_000_000))
            }
        }
    }

    private func effectiveLimit(queueID: UUID?) -> Int64? {
        let queue = queueID.flatMap { queueLimits[$0] }
        switch (globalLimit, queue) {
        case let (g?, q?): return min(g, q)
        case let (g?, nil): return g
        case let (nil, q?): return q
        default: return nil
        }
    }
}

public enum PartialFile {
    public static func create(at url: URL, size: Int64?) throws -> Int32 {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let fd = open(url.path, O_RDWR)
        if fd < 0 {
            throw FluxError.filesystem("Unable to open partial file.")
        }
        if let size, size > 0 {
            if ftruncate(fd, off_t(size)) != 0 {
                close(fd)
                throw FluxError.filesystem("Unable to preallocate partial file.")
            }
        }
        return fd
    }

    public static func write(fd: Int32, data: Data, offset: Int64) throws {
        try data.withUnsafeBytes { raw in
            var written = 0
            let total = raw.count
            while written < total {
                let n = pwrite(fd, raw.baseAddress!.advanced(by: written), total - written, off_t(offset) + off_t(written))
                if n < 0 {
                    throw FluxError.filesystem("Write failed at offset \(offset).")
                }
                written += n
            }
        }
    }

    public static func syncAndClose(_ fd: Int32) {
        fsync(fd)
        close(fd)
    }

    public static func finalize(temporary: URL, final: URL, expectedSize: Int64?) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: temporary.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if let expectedSize, expectedSize > 0, size != expectedSize {
            throw FluxError.incompleteFile
        }
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.moveItem(at: temporary, to: final)
    }
}
