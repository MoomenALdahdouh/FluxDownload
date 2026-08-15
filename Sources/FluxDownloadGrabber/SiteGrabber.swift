import Foundation
import FluxDownloadCore

public struct GrabberOptions: Sendable {
    public var startURL: URL
    public var scope: GrabberScope
    public var types: [GrabberResourceType]
    public var maxDepth: Int
    public var maxURLs: Int
    public var delayNanoseconds: UInt64
    public var respectRobots: Bool

    public init(
        startURL: URL,
        scope: GrabberScope = .page,
        types: [GrabberResourceType] = GrabberResourceType.allCases,
        maxDepth: Int = 1,
        maxURLs: Int = 200,
        delayNanoseconds: UInt64 = 150_000_000,
        respectRobots: Bool = true
    ) {
        self.startURL = startURL
        self.scope = scope
        self.types = types
        self.maxDepth = min(max(0, maxDepth), 5)
        self.maxURLs = min(max(1, maxURLs), 2_000)
        self.delayNanoseconds = delayNanoseconds
        self.respectRobots = respectRobots
    }
}

public actor SiteGrabber {
    private var cancelled = false

    public init() {}

    public func cancel() { cancelled = true }

    public func crawl(_ options: GrabberOptions, session: URLSession = .shared) async throws -> [GrabberItem] {
        cancelled = false
        var robots = RobotsRules(disallow: [])
        if options.respectRobots {
            var robotsURL = options.startURL
            robotsURL = URL(string: "http://\(options.startURL.host ?? "localhost")/robots.txt")!
            if let scheme = options.startURL.scheme, let host = options.startURL.host {
                var comps = URLComponents()
                comps.scheme = scheme
                comps.host = host
                comps.port = options.startURL.port
                comps.path = "/robots.txt"
                if let url = comps.url, let text = try? await fetchText(url, session: session) {
                    robots = RobotsRules.parse(text)
                }
            }
            _ = robotsURL
        }
        var visited = Set<String>()
        var items: [GrabberItem] = []
        var queue: [(URL, Int)] = [(options.startURL, 0)]
        visited.insert(options.startURL.absoluteString)

        while let (url, depth) = queue.first {
            queue.removeFirst()
            if cancelled { throw FluxError.cancelled }
            if items.count + queue.count >= options.maxURLs { throw FluxError.grabberLimitReached("Maximum URL count.") }
            if !allowed(url, start: options.startURL, scope: options.scope) { continue }
            if robots.disallows(url.path) { continue }
            try await Task.sleep(nanoseconds: options.delayNanoseconds)
            if cancelled { throw FluxError.cancelled }
            let html = try await fetchText(url, session: session)
            let links = LinkExtractor.extract(html, base: url)
            for link in links {
                if cancelled { throw FluxError.cancelled }
                if visited.contains(link.absoluteString) { continue }
                if !allowed(link, start: options.startURL, scope: options.scope) { continue }
                if robots.disallows(link.path) { continue }
                visited.insert(link.absoluteString)
                if matches(link, types: options.types) {
                    items.append(GrabberItem(url: link.absoluteString, filename: try? FilenameSanitizer.fromURL(link)))
                    if items.count >= options.maxURLs { return items }
                } else if depth < options.maxDepth, isHTML(link) {
                    queue.append((link, depth + 1))
                }
            }
        }
        return items
    }

    private func fetchText(_ url: URL, session: URLSession) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(Brand.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !HTTPStatusMapper.isSuccess(http.statusCode) {
            throw HTTPStatusMapper.error(for: http.statusCode)
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private func allowed(_ url: URL, start: URL, scope: GrabberScope) -> Bool {
        guard url.scheme == "http" || url.scheme == "https" else { return false }
        switch scope {
        case .page:
            return url.absoluteString == start.absoluteString || url.deletingLastPathComponent().absoluteString == start.deletingLastPathComponent().absoluteString
        case .directory:
            return url.host == start.host && url.path.hasPrefix(directoryPrefix(start))
        case .domain:
            return url.host == start.host
        case .custom:
            return url.host == start.host
        }
    }

    private func directoryPrefix(_ url: URL) -> String {
        if url.pathExtension.isEmpty { return url.path }
        return url.deletingLastPathComponent().path
    }

    private func isHTML(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty || ext == "html" || ext == "htm"
    }

    private func matches(_ url: URL, types: [GrabberResourceType]) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return false }
        for type in types {
            if type.extensions.contains(ext) { return true }
            if type == .other { return true }
        }
        return false
    }
}

struct RobotsRules {
    var disallow: [String]

    static func parse(_ text: String) -> RobotsRules {
        var rules: [String] = []
        var applies = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("user-agent:") {
                let value = line.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
                applies = value == "*" || value.lowercased().contains("flux")
            } else if applies, line.lowercased().hasPrefix("disallow:") {
                let value = line.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { rules.append(value) }
            }
        }
        return RobotsRules(disallow: rules)
    }

    func disallows(_ path: String) -> Bool {
        disallow.contains { path.hasPrefix($0) }
    }
}

enum LinkExtractor {
    static func extract(_ html: String, base: URL) -> [URL] {
        var urls: [URL] = []
        let pattern = #"(?:href|src)\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, let swift = Range(match.range(at: 1), in: html) else { return }
            let raw = String(html[swift])
            if let url = URL(string: raw, relativeTo: base)?.absoluteURL, url.scheme == "http" || url.scheme == "https" {
                urls.append(url)
            }
        }
        return urls
    }
}
