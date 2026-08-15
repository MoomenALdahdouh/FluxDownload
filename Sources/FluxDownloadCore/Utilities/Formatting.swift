import Foundation

public enum ByteFormat: Sendable {
    public static func string(_ bytes: Int64) -> String {
        let value = Double(bytes)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var n = value
        var idx = 0
        while n >= 1024 && idx < units.count - 1 {
            n /= 1024
            idx += 1
        }
        if idx == 0 { return "\(bytes) \(units[idx])" }
        return String(format: "%.1f %@", n, units[idx])
    }

    public static func speed(_ bytesPerSecond: Int64) -> String {
        "\(string(bytesPerSecond))/s"
    }

    public static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

public enum HTTPStatusMapper: Sendable {
    public static func error(for status: Int) -> FluxError {
        switch status {
        case 401, 403: return .accessDenied
        case 404: return .notFound
        case 408: return .timeout
        case 429: return .rateLimited
        case 500...599: return .serverFailure(status: status)
        default: return .serverFailure(status: status)
        }
    }

    public static func isSuccess(_ status: Int) -> Bool {
        (200...299).contains(status)
    }
}

public enum DiskSpace: Sendable {
    public static func available(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        if let available = values.volumeAvailableCapacity {
            return Int64(available)
        }
        throw FluxError.filesystem("Unable to determine free disk space.")
    }

    public static func ensureAvailable(at url: URL, needed: Int64, margin: Int64 = 8 * 1024 * 1024) throws {
        guard needed > 0 else { return }
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let free = try available(at: directory)
        if free < needed + margin {
            throw FluxError.insufficientDiskSpace(needed: needed, available: free)
        }
    }
}

public enum RetryPolicy: Sendable {
    public static func delay(forAttempt attempt: Int, base: TimeInterval = 0.8, cap: TimeInterval = 30) -> TimeInterval {
        let exp = min(cap, base * pow(2, Double(max(0, attempt))))
        let jitter = Double.random(in: 0...0.25) * exp
        return min(cap, exp + jitter)
    }
}

public struct UpdateChecking: Sendable {
    public static let shared = UpdateChecking()
    public func checkForUpdates() {
        AppLog.info("Update checking is not configured.", category: "update")
    }
}
