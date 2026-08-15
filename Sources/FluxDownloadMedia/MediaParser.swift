import Foundation
import FluxDownloadCore

public struct MediaRepresentation: Sendable, Equatable, Identifiable {
    public var id: String
    public var url: URL
    public var container: String
    public var width: Int?
    public var height: Int?
    public var bandwidth: Int?
    public var frameRate: Double?
    public var codecs: String?
    public var hasAudio: Bool
    public var hasVideo: Bool
    public var approximateSize: Int64?
    public var isProtected: Bool

    public var resolutionLabel: String {
        if let height { return "\(height)p" }
        if hasAudio && !hasVideo { return "Audio" }
        return container.uppercased()
    }

    public init(
        id: String = UUID().uuidString,
        url: URL,
        container: String,
        width: Int? = nil,
        height: Int? = nil,
        bandwidth: Int? = nil,
        frameRate: Double? = nil,
        codecs: String? = nil,
        hasAudio: Bool = true,
        hasVideo: Bool = true,
        approximateSize: Int64? = nil,
        isProtected: Bool = false
    ) {
        self.id = id
        self.url = url
        self.container = container
        self.width = width
        self.height = height
        self.bandwidth = bandwidth
        self.frameRate = frameRate
        self.codecs = codecs
        self.hasAudio = hasAudio
        self.hasVideo = hasVideo
        self.approximateSize = approximateSize
        self.isProtected = isProtected
    }
}

public struct MediaGroup: Sendable, Equatable, Identifiable {
    public var id: String
    public var pageURL: URL?
    public var representations: [MediaRepresentation]
    public var isProtected: Bool { representations.contains(where: \.isProtected) }

    public init(id: String = UUID().uuidString, pageURL: URL? = nil, representations: [MediaRepresentation]) {
        self.id = id
        self.pageURL = pageURL
        self.representations = representations
    }

    public var visibleRepresentations: [MediaRepresentation] {
        representations.filter { !$0.isProtected }
    }
}

public enum HLSParser {
    public static func parse(_ text: String, base: URL) throws -> MediaGroup {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard lines.first?.hasPrefix("#EXTM3U") == true else {
            throw FluxError.unsupportedMedia
        }
        var protected = false
        var representations: [MediaRepresentation] = []
        var pending: [String: String] = [:]
        for line in lines {
            if line.hasPrefix("#EXT-X-KEY") {
                let method = attribute(line, "METHOD") ?? ""
                if method.uppercased().contains("SAMPLE-AES") || method.uppercased().contains("FAIRPLAY") || method == "SAMPLE-AES-CTR" {
                    protected = true
                }
            }
            if line.hasPrefix("#EXT-X-SESSION-KEY") {
                let method = attribute(line, "METHOD") ?? ""
                if method.uppercased().contains("SAMPLE-AES") { protected = true }
            }
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pending = attributes(line)
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
            let resolution = pending["RESOLUTION"]?.split(separator: "x")
            let width = resolution.flatMap { Int($0.first ?? "") }
            let height = resolution.flatMap { Int($0.last ?? "") }
            let bandwidth = pending["BANDWIDTH"].flatMap { Int($0) }
            let codecs = pending["CODECS"]
            let frameRate = pending["FRAME-RATE"].flatMap { Double($0) }
            representations.append(
                MediaRepresentation(
                    url: url,
                    container: url.pathExtension.isEmpty ? "m3u8" : url.pathExtension,
                    width: width,
                    height: height,
                    bandwidth: bandwidth,
                    frameRate: frameRate,
                    codecs: codecs,
                    hasAudio: true,
                    hasVideo: height != nil,
                    isProtected: protected
                )
            )
            pending = [:]
        }
        if representations.isEmpty && protected {
            throw FluxError.protectedMedia
        }
        if representations.isEmpty {
            representations.append(
                MediaRepresentation(
                    url: base,
                    container: "m3u8",
                    hasAudio: true,
                    hasVideo: true,
                    isProtected: protected
                )
            )
        }
        if protected {
            representations = representations.map {
                var copy = $0
                copy.isProtected = true
                return copy
            }
        }
        return MediaGroup(representations: representations)
    }

    private static func attributes(_ line: String) -> [String: String] {
        guard let idx = line.firstIndex(of: ":") else { return [:] }
        return parseAttributes(String(line[line.index(after: idx)...]))
    }

    private static func attribute(_ line: String, _ name: String) -> String? {
        attributes(line)[name]
    }

    static func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var current = ""
        var key: String?
        var inQuotes = false
        func commit(_ value: String) {
            if let key { result[key] = value }
        }
        for ch in text {
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch == "=" && !inQuotes && key == nil {
                key = current
                current = ""
                continue
            }
            if ch == "," && !inQuotes {
                commit(current)
                current = ""
                key = nil
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { commit(current) }
        return result
    }
}

public enum DASHParser {
    public static func parse(_ xml: String, base: URL) throws -> MediaGroup {
        if xml.contains("<ContentProtection") || xml.lowercased().contains("cenc:pssh") || xml.contains("urn:mpeg:cenc") {
            throw FluxError.protectedMedia
        }
        var representations: [MediaRepresentation] = []
        let regex = try NSRegularExpression(pattern: "<Representation\\b([^>]*)>([\\s\\S]*?)</Representation>", options: [.caseInsensitive])
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        regex.enumerateMatches(in: xml, range: range) { match, _, _ in
            guard let match, let attrRange = Range(match.range(at: 1), in: xml) else { return }
            let attrs = HLSParser.parseAttributes(String(xml[attrRange]).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "\""))
            // simpler attribute grab
            let width = intAttr(String(xml[attrRange]), "width")
            let height = intAttr(String(xml[attrRange]), "height")
            let bandwidth = intAttr(String(xml[attrRange]), "bandwidth")
            let codecs = stringAttr(String(xml[attrRange]), "codecs")
            let mime = stringAttr(String(xml[attrRange]), "mimeType") ?? "video/mp4"
            var url = base
            if let bodyRange = Range(match.range(at: 2), in: xml) {
                let body = String(xml[bodyRange])
                if let baseURL = firstTag(body, "BaseURL"), let resolved = URL(string: baseURL, relativeTo: base)?.absoluteURL {
                    url = resolved
                }
            }
            representations.append(
                MediaRepresentation(
                    url: url,
                    container: mime.contains("mp4") ? "mp4" : (mime.contains("webm") ? "webm" : "mpd"),
                    width: width,
                    height: height,
                    bandwidth: bandwidth,
                    codecs: codecs,
                    hasAudio: mime.contains("audio") || height == nil,
                    hasVideo: mime.contains("video") || height != nil
                )
            )
            _ = attrs
        }
        if representations.isEmpty {
            throw FluxError.unsupportedMedia
        }
        return MediaGroup(representations: representations)
    }

    private static func intAttr(_ text: String, _ name: String) -> Int? {
        stringAttr(text, name).flatMap(Int.init)
    }

    private static func stringAttr(_ text: String, _ name: String) -> String? {
        let pattern = #"\#(name)\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let swift = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[swift])
    }

    private static func firstTag(_ text: String, _ name: String) -> String? {
        let pattern = "<\(name)>([^<]+)</\(name)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let swift = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[swift]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum MediaDetector {
    public static func fromDirectURL(_ url: URL, mimeType: String?) -> MediaRepresentation? {
        let ext = url.pathExtension.lowercased()
        let mime = mimeType?.lowercased() ?? ""
        let videoExt = ["mp4", "webm", "mov", "m4v", "mkv", "mpeg", "mpg"]
        let audioExt = ["mp3", "m4a", "aac", "wav", "ogg", "flac"]
        if videoExt.contains(ext) || mime.hasPrefix("video/") {
            return MediaRepresentation(url: url, container: ext.isEmpty ? "mp4" : ext, hasAudio: true, hasVideo: true)
        }
        if audioExt.contains(ext) || mime.hasPrefix("audio/") {
            return MediaRepresentation(url: url, container: ext.isEmpty ? "audio" : ext, hasAudio: true, hasVideo: false)
        }
        if ext == "m3u8" || mime.contains("mpegurl") {
            return MediaRepresentation(url: url, container: "m3u8")
        }
        if ext == "mpd" || mime.contains("dash+xml") {
            return MediaRepresentation(url: url, container: "mpd")
        }
        return nil
    }

    public static func group(from urls: [URL], mimeTypes: [String] = []) -> MediaGroup {
        var reps: [MediaRepresentation] = []
        for (index, url) in urls.enumerated() {
            let mime = mimeTypes.indices.contains(index) ? mimeTypes[index] : nil
            if let rep = fromDirectURL(url, mimeType: mime) {
                reps.append(rep)
            }
        }
        return MediaGroup(representations: unique(reps))
    }

    public static func unique(_ items: [MediaRepresentation]) -> [MediaRepresentation] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.url.absoluteString).inserted }
    }
}
