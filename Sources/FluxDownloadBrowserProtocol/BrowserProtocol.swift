import Foundation
import FluxDownloadCore

public enum BrowserProtocolVersion {
    public static let current = 1
    public static let maxInboundBytes = 64 * 1024 * 1024
    public static let maxOutboundBytes = 1024 * 1024
}

public enum BrowserSource: String, Codable, Sendable {
    case chrome
    case chromium
    case safari
    case cli
    case app
}

public enum BrowserCommandType: String, Codable, Sendable, CaseIterable {
    case ping
    case downloadRequest = "download.request"
    case downloadCapture = "download.capture"
    case mediaDetected = "media.detected"
    case statusQuery = "status.query"
    case settingsGet = "settings.get"
}

public struct BrowserEnvelope: Codable, Sendable, Equatable {
    public var version: Int
    public var type: BrowserCommandType
    public var id: String
    public var token: String?
    public var payload: BrowserPayload

    public init(version: Int = BrowserProtocolVersion.current, type: BrowserCommandType, id: String = UUID().uuidString, token: String? = nil, payload: BrowserPayload) {
        self.version = version
        self.type = type
        self.id = id
        self.token = token
        self.payload = payload
    }
}

public enum BrowserPayload: Codable, Sendable, Equatable {
    case ping
    case download(DownloadRequestPayload)
    case media(MediaDetectedPayload)
    case empty

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.url) {
            self = .download(try DownloadRequestPayload(from: decoder))
        } else if container.contains(.resources) {
            self = .media(try MediaDetectedPayload(from: decoder))
        } else {
            self = .empty
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .ping, .empty:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeNil(forKey: .placeholder)
        case .download(let payload):
            try payload.encode(to: encoder)
        case .media(let payload):
            try payload.encode(to: encoder)
        }
    }

    private enum CodingKeys: String, CodingKey { case url, resources, placeholder }
}

public struct DownloadRequestPayload: Codable, Sendable, Equatable {
    public var url: String
    public var pageURL: String?
    public var referrer: String?
    public var filename: String?
    public var mimeType: String?
    public var source: BrowserSource
    public var browserRequestId: String?
    public var fileSize: Int64?
    public var headers: [String: String]?
    public var cookies: String?
    public var userAgent: String?
    public var capture: Bool
    /// When false, the Mac app still queues the file but does not pop a status window.
    public var openStatusWindow: Bool?

    public init(
        url: String,
        pageURL: String? = nil,
        referrer: String? = nil,
        filename: String? = nil,
        mimeType: String? = nil,
        source: BrowserSource = .chrome,
        browserRequestId: String? = nil,
        fileSize: Int64? = nil,
        headers: [String: String]? = nil,
        cookies: String? = nil,
        userAgent: String? = nil,
        capture: Bool = false,
        openStatusWindow: Bool? = nil
    ) {
        self.url = url
        self.pageURL = pageURL
        self.referrer = referrer
        self.filename = filename
        self.mimeType = mimeType
        self.source = source
        self.browserRequestId = browserRequestId
        self.fileSize = fileSize
        self.headers = headers
        self.cookies = cookies
        self.userAgent = userAgent
        self.capture = capture
        self.openStatusWindow = openStatusWindow
    }
}

public struct MediaResourcePayload: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var url: String
    public var mimeType: String?
    public var width: Int?
    public var height: Int?
    public var bandwidth: Int?
    public var codecs: String?
    public var hasAudio: Bool
    public var hasVideo: Bool
    public var container: String?
    public var protected: Bool

    public init(
        id: String = UUID().uuidString,
        url: String,
        mimeType: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        bandwidth: Int? = nil,
        codecs: String? = nil,
        hasAudio: Bool = true,
        hasVideo: Bool = true,
        container: String? = nil,
        protected: Bool = false
    ) {
        self.id = id
        self.url = url
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.bandwidth = bandwidth
        self.codecs = codecs
        self.hasAudio = hasAudio
        self.hasVideo = hasVideo
        self.container = container
        self.protected = protected
    }
}

public struct MediaDetectedPayload: Codable, Sendable, Equatable {
    public var pageURL: String
    public var resources: [MediaResourcePayload]

    public init(pageURL: String, resources: [MediaResourcePayload]) {
        self.pageURL = pageURL
        self.resources = resources
    }
}

public struct BrowserResponse: Codable, Sendable, Equatable {
    public var version: Int
    public var id: String
    public var ok: Bool
    public var error: String?
    public var diagnostic: String?
    public var downloadID: String?
    public var connected: Bool?
    public var appVersion: String?
    public var captureEnabled: Bool?

    public init(
        version: Int = BrowserProtocolVersion.current,
        id: String,
        ok: Bool,
        error: String? = nil,
        diagnostic: String? = nil,
        downloadID: String? = nil,
        connected: Bool? = true,
        appVersion: String? = Brand.version,
        captureEnabled: Bool? = nil
    ) {
        self.version = version
        self.id = id
        self.ok = ok
        self.error = error
        self.diagnostic = diagnostic
        self.downloadID = downloadID
        self.connected = connected
        self.appVersion = appVersion
        self.captureEnabled = captureEnabled
    }
}

public enum BrowserMessageValidator: Sendable {
    public static func decode(_ data: Data) throws -> BrowserEnvelope {
        if data.count > BrowserProtocolVersion.maxInboundBytes {
            throw FluxError.ipcPayloadTooLarge
        }
        let decoder = JSONDecoder()
        let envelope: BrowserEnvelope
        do {
            envelope = try decoder.decode(BrowserEnvelope.self, from: data)
        } catch {
            throw FluxError.protocolError("Malformed JSON payload.")
        }
        try validate(envelope)
        return envelope
    }

    public static func validate(_ envelope: BrowserEnvelope) throws {
        guard envelope.version == BrowserProtocolVersion.current else {
            throw FluxError.protocolError("Unsupported protocol version \(envelope.version).")
        }
        guard BrowserCommandType.allCases.contains(envelope.type) else {
            throw FluxError.ipcUnknownCommand(envelope.type.rawValue)
        }
        switch envelope.payload {
        case .download(let payload):
            _ = try URLValidator.parse(payload.url)
            if let page = payload.pageURL, !page.isEmpty { _ = try URLValidator.parse(page) }
            if let referrer = payload.referrer, !referrer.isEmpty { _ = try URLValidator.parse(referrer) }
            if let filename = payload.filename {
                _ = try FilenameSanitizer.sanitize(filename)
            }
            if let cookies = payload.cookies, cookies.count > 16_384 {
                throw FluxError.protocolError("Cookie field exceeds limit.")
            }
        case .media(let payload):
            if !payload.pageURL.isEmpty { _ = try URLValidator.parse(payload.pageURL) }
            for resource in payload.resources {
                _ = try URLValidator.parse(resource.url)
            }
        case .ping, .empty:
            break
        }
    }

    public static func encode(_ response: BrowserResponse) throws -> Data {
        let data = try JSONEncoder().encode(response)
        if data.count > BrowserProtocolVersion.maxOutboundBytes {
            throw FluxError.ipcPayloadTooLarge
        }
        return data
    }
}

public enum NativeMessagingCodec: Sendable {
    public static func readMessage(from handle: FileHandle, maxBytes: Int = BrowserProtocolVersion.maxInboundBytes) throws -> Data? {
        let lengthData = handle.readData(ofLength: 4)
        if lengthData.isEmpty { return nil }
        guard lengthData.count == 4 else { throw FluxError.protocolError("Truncated native messaging length.") }
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }
        if length == 0 { return Data() }
        if Int(length) > maxBytes { throw FluxError.ipcPayloadTooLarge }
        let payload = handle.readData(ofLength: Int(length))
        guard payload.count == Int(length) else { throw FluxError.protocolError("Truncated native messaging payload.") }
        return payload
    }

    public static func writeMessage(_ data: Data, to handle: FileHandle) throws {
        if data.count > BrowserProtocolVersion.maxOutboundBytes {
            throw FluxError.ipcPayloadTooLarge
        }
        var length = UInt32(data.count)
        let header = Data(bytes: &length, count: 4)
        handle.write(header)
        handle.write(data)
    }
}
