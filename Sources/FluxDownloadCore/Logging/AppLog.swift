import Foundation

public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug = 0
    case info = 1
    case notice = 2
    case warning = 3
    case error = 4
    case critical = 5

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Structured logger that redacts sensitive values by field type, not by guessing in free text.
public struct AppLog: Sendable {
    nonisolated(unsafe) public static var minimumLevel: LogLevel = .info
    nonisolated(unsafe) public static var sink: @Sendable (LogLevel, String, String) -> Void = { level, category, message in
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] [\(level)] [\(category)] \(message)\n".utf8))
    }

    public static func debug(_ message: String, category: String = "app") {
        log(.debug, category: category, message: message)
    }

    public static func info(_ message: String, category: String = "app") {
        log(.info, category: category, message: message)
    }

    public static func notice(_ message: String, category: String = "app") {
        log(.notice, category: category, message: message)
    }

    public static func warning(_ message: String, category: String = "app") {
        log(.warning, category: category, message: message)
    }

    public static func error(_ message: String, category: String = "app") {
        log(.error, category: category, message: message)
    }

    public static func critical(_ message: String, category: String = "app") {
        log(.critical, category: category, message: message)
    }

    public static func log(_ level: LogLevel, category: String, message: String) {
        guard level >= minimumLevel else { return }
        sink(level, category, Redactor.redactFreeText(message))
    }
}

public enum Redactor: Sendable {
    public static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "x-auth-token"
    ]

    public static func isSensitiveHeader(_ name: String) -> Bool {
        sensitiveHeaderNames.contains(name.lowercased())
    }

    public static func redactHeaders(_ headers: [String: String]) -> [String: String] {
        var copy = headers
        for key in copy.keys where isSensitiveHeader(key) {
            copy[key] = "<redacted>"
        }
        return copy
    }

    public static func redactURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let items = components?.queryItems, !items.isEmpty {
            components?.queryItems = items.map { item in
                let name = item.name.lowercased()
                if name.contains("token") || name.contains("key") || name.contains("password") || name.contains("auth") || name.contains("sig") {
                    return URLQueryItem(name: item.name, value: "<redacted>")
                }
                return item
            }
        }
        return components?.string ?? url.absoluteString
    }

    /// Best-effort scrub of leftover credential-shaped substrings in already-structured messages.
    public static func redactFreeText(_ text: String) -> String {
        var result = text
        let patterns = [
            #"(?i)(authorization:\s*)\S+"#,
            #"(?i)(cookie:\s*)\S+"#,
            #"(?i)(password=)\S+"#,
            #"(?i)(access_token=)\S+"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1<redacted>")
            }
        }
        return result
    }
}
