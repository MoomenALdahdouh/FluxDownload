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

public struct HLSSegment: Sendable, Equatable {
    public var url: URL
    public var duration: Double?
    public var byteOffset: Int64?
    public var byteLength: Int64?

    public init(url: URL, duration: Double? = nil, byteOffset: Int64? = nil, byteLength: Int64? = nil) {
        self.url = url
        self.duration = duration
        self.byteOffset = byteOffset
        self.byteLength = byteLength
    }
}

public struct HLSSegmentList: Sendable, Equatable {
    public var mapURL: URL?
    public var mapByteOffset: Int64?
    public var mapByteLength: Int64?
    public var segments: [HLSSegment]
    public var isProtected: Bool
    public var isMaster: Bool
    public var usesFMP4: Bool { mapURL != nil }

    public var downloadURLs: [URL] {
        var urls: [URL] = []
        if let mapURL { urls.append(mapURL) }
        urls.append(contentsOf: segments.map(\.url))
        return urls
    }

    public init(
        mapURL: URL? = nil,
        mapByteOffset: Int64? = nil,
        mapByteLength: Int64? = nil,
        segments: [HLSSegment],
        isProtected: Bool = false,
        isMaster: Bool = false
    ) {
        self.mapURL = mapURL
        self.mapByteOffset = mapByteOffset
        self.mapByteLength = mapByteLength
        self.segments = segments
        self.isProtected = isProtected
        self.isMaster = isMaster
    }
}

public enum HLSParser {
    public static func looksLikePlaylist(url: URL, mimeType: String? = nil) -> Bool {
        if isLinkedInSegment(url) { return false }
        let mime = (mimeType ?? "").lowercased()
        if mime.contains("mpegurl") { return true }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if path.contains(".m3u8") || path.hasSuffix(".m3u") { return true }
        if host.contains("licdn.com") {
            if path.contains("webvtt") || path.contains("caption") || path.contains("subtitle") { return false }
            if path.contains("/playlist/vid/dash/") || path.contains("/dms/image/") || path.contains("videocover") { return false }
            return path.contains("/playlist/") || path.contains("/vid/")
        }
        return false
    }

    public static func isLinkedInHost(_ url: URL) -> Bool {
        url.host?.lowercased().contains("licdn.com") == true
    }

    public static func isLinkedInSegment(_ url: URL) -> Bool {
        guard isLinkedInHost(url) else { return false }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return false }
        return parts[parts.count - 1].allSatisfy(\.isNumber)
            && parts[parts.count - 2].allSatisfy(\.isNumber)
    }

    public static func normalizedPlaylistURL(_ url: URL) -> URL {
        let host = url.host?.lowercased() ?? ""
        guard host.contains("licdn.com") else { return url }
        var parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2,
              parts[parts.count - 1].allSatisfy(\.isNumber),
              parts[parts.count - 2].allSatisfy(\.isNumber) else {
            return url
        }
        parts.removeLast(2)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/" + parts.joined(separator: "/")
        return components?.url ?? url
    }

    public static func isJunkLinkedInMedia(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("webvtt") || path.contains("caption") || path.contains("subtitle")
            || path.contains("/playlist/vid/dash/")
            || path.contains("/dms/image/")
            || path.contains("videocover")
    }

    public static func isPlaylistText(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
    }

    public static func isPlaylistData(_ data: Data) -> Bool {
        var slice = data
        if slice.starts(with: [0xEF, 0xBB, 0xBF]) {
            slice = slice.dropFirst(3)
        }
        guard let text = String(data: slice.prefix(16), encoding: .utf8) else { return false }
        return isPlaylistText(text)
    }

    public static func parse(_ text: String, base: URL) throws -> MediaGroup {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { $0.hasPrefix("#EXTM3U") }) else {
            throw FluxError.unsupportedMedia
        }
        var protected = false
        var representations: [MediaRepresentation] = []
        var pending: [String: String] = [:]
        for line in lines {
            if line.hasPrefix("#EXT-X-KEY") || line.hasPrefix("#EXT-X-SESSION-KEY") {
                let method = (attribute(line, "METHOD") ?? "").uppercased()
                if method.contains("SAMPLE-AES") || method.contains("FAIRPLAY") || method == "SAMPLE-AES-CTR" {
                    protected = true
                }
            }
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pending = attributes(line)
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard !pending.isEmpty else { continue }
            guard let url = URL(string: line, relativeTo: base)?.absoluteURL else {
                pending = [:]
                continue
            }
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

    public static func segmentList(_ text: String, base: URL) throws -> HLSSegmentList {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { $0.hasPrefix("#EXTM3U") }) else {
            throw FluxError.unsupportedMedia
        }
        var protected = false
        var isMaster = false
        var mapURL: URL?
        var mapByteOffset: Int64?
        var mapByteLength: Int64?
        var segments: [HLSSegment] = []
        var pendingDuration: Double?
        var pendingRange: (offset: Int64, length: Int64)?
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                isMaster = true
            }
            if line.hasPrefix("#EXT-X-KEY") || line.hasPrefix("#EXT-X-SESSION-KEY") {
                let method = (attribute(line, "METHOD") ?? "NONE").uppercased()
                if method != "NONE" && !method.isEmpty {
                    protected = true
                }
            }
            if line.hasPrefix("#EXT-X-MAP") {
                if let uri = attribute(line, "URI") {
                    mapURL = URL(string: uri, relativeTo: base)?.absoluteURL
                }
                if let range = parseByteRange(attribute(line, "BYTERANGE")) {
                    mapByteOffset = range.offset
                    mapByteLength = range.length
                }
            }
            if line.hasPrefix("#EXTINF:") {
                let value = String(line.dropFirst(8)).split(separator: ",").first.map(String.init) ?? ""
                pendingDuration = Double(value)
                continue
            }
            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = parseByteRange(String(line.dropFirst(17).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if isMaster { continue }
            guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
            segments.append(
                HLSSegment(
                    url: url,
                    duration: pendingDuration,
                    byteOffset: pendingRange?.offset,
                    byteLength: pendingRange?.length
                )
            )
            pendingDuration = nil
            pendingRange = nil
        }
        if protected {
            throw FluxError.protectedMedia
        }
        if isMaster {
            return HLSSegmentList(
                mapURL: nil,
                mapByteOffset: nil,
                mapByteLength: nil,
                segments: [],
                isProtected: false,
                isMaster: true
            )
        }
        if segments.isEmpty && mapURL == nil {
            throw FluxError.unsupportedMedia
        }
        return HLSSegmentList(
            mapURL: mapURL,
            mapByteOffset: mapByteOffset,
            mapByteLength: mapByteLength,
            segments: segments,
            isProtected: false,
            isMaster: false
        )
    }

    private static func parseByteRange(_ raw: String?) -> (offset: Int64, length: Int64)? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "@", maxSplits: 1).map(String.init)
        guard let length = Int64(parts[0]) else { return nil }
        let offset = parts.count > 1 ? Int64(parts[1]) : 0
        return (offset ?? 0, length)
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
        if HLSParser.looksLikePlaylist(url: url, mimeType: mimeType) {
            return MediaRepresentation(url: url, container: "m3u8")
        }
        if videoExt.contains(ext) || mime.hasPrefix("video/") {
            return MediaRepresentation(url: url, container: ext.isEmpty ? "mp4" : ext, hasAudio: true, hasVideo: true)
        }
        if audioExt.contains(ext) || mime.hasPrefix("audio/") {
            return MediaRepresentation(url: url, container: ext.isEmpty ? "audio" : ext, hasAudio: true, hasVideo: false)
        }
        if ext == "m3u8" || ext == "m3u" || mime.contains("mpegurl") {
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
