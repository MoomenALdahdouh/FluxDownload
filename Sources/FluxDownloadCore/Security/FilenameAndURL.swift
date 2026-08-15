import Foundation

public enum URLValidator: Sendable {
    public static let allowedSchemes: Set<String> = ["http", "https"]

    public static func parse(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FluxError.invalidURL(raw) }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw FluxError.invalidURL(raw)
        }
        guard allowedSchemes.contains(scheme) else {
            throw FluxError.unsupportedScheme(scheme)
        }
        guard url.host != nil else { throw FluxError.invalidURL(raw) }
        return url
    }

    public static func extractURLs(from text: String) -> [URL] {
        var found: [URL] = []
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        detector?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            if let match, let url = match.url, (try? parse(url.absoluteString)) != nil {
                found.append(url)
            }
        }
        return found
    }

    public static func normalized(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        if let items = components?.queryItems {
            let filtered = items.filter { item in
                let name = item.name.lowercased()
                return !(name.hasPrefix("utm_") || name == "fbclid")
            }
            components?.queryItems = filtered.isEmpty ? nil : filtered
        }
        let string = components?.string ?? url.absoluteString
        if string.hasSuffix("/") && (url.path.isEmpty || url.path == "/") {
            return string
        }
        return string
    }
}

public enum FilenameSanitizer: Sendable {
    private static let maxLength = 240
    private static let reserved = Set([".", "..", "CON", "PRN", "AUX", "NUL"])

    public static func sanitize(_ raw: String) throws -> String {
        var name = raw
        let parts = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        if parts.contains("..") || raw.hasPrefix("/") && raw.contains("..") {
            throw FluxError.pathTraversal
        }
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        if name.contains("\\") {
            name = name.split(separator: "\\").last.map(String.init) ?? name
        }
        if name.contains("\0") { throw FluxError.invalidFilename }
        if name.contains("..") && (name.contains("/") || name.contains("\\")) {
            throw FluxError.pathTraversal
        }

        let illegal = CharacterSet(charactersIn: "/\\:\0")
        name = name.components(separatedBy: illegal).joined(separator: "_")
        name = name.replacingOccurrences(of: "\u{202E}", with: "")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "download" }
        if reserved.contains(name.uppercased()) { name = "download" }

        if name.utf8.count > maxLength {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            var truncated = String(base.prefix(maxLength - ext.count - 1))
            if !ext.isEmpty { truncated += ".\(ext)" }
            name = truncated
        }
        return name
    }

    public static func fromURL(_ url: URL) throws -> String {
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" { return try sanitize("download") }
        return try sanitize(last)
    }

    public static func fromContentDisposition(_ header: String?) throws -> String? {
        guard let header else { return nil }
        if let star = match(header, pattern: #"filename\*\s*=\s*UTF-8''([^;]+)"#) {
            let decoded = star.removingPercentEncoding ?? star
            return try sanitize(decoded)
        }
        if let quoted = match(header, pattern: #"filename\s*=\s*"([^"]+)""#) {
            return try sanitize(quoted)
        }
        if let plain = match(header, pattern: #"filename\s*=\s*([^;]+)"#) {
            return try sanitize(plain.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    public static func uniquify(directory: URL, filename: String) -> String {
        let fm = FileManager.default
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        var candidate = filename
        var index = 1
        while fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            if ext.isEmpty {
                candidate = "\(base) (\(index))"
            } else {
                candidate = "\(base) (\(index)).\(ext)"
            }
            index += 1
        }
        return candidate
    }

    public static func `extension`(from filename: String) -> String {
        URL(fileURLWithPath: filename).pathExtension.lowercased()
    }

    private static func match(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[swiftRange])
    }
}

public enum CollisionResolver: Sendable {
    public static func resolve(
        directory: URL,
        filename: String,
        policy: DuplicatePolicy
    ) throws -> String? {
        let dest = directory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: dest.path) {
            return filename
        }
        switch policy {
        case .ask:
            return nil
        case .replace:
            return filename
        case .keepBoth, .rename:
            return FilenameSanitizer.uniquify(directory: directory, filename: filename)
        case .cancel:
            throw FluxError.cancelled
        }
    }
}
