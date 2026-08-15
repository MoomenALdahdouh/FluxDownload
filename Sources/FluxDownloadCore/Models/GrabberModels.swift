import Foundation

public enum GrabberScope: String, Codable, Sendable, CaseIterable {
    case page
    case directory
    case domain
    case custom
}

public enum GrabberResourceType: String, Codable, Sendable, CaseIterable {
    case images
    case videos
    case audio
    case documents
    case archives
    case scripts
    case stylesheets
    case other

    public var extensions: [String] {
        switch self {
        case .images: return ["jpg", "jpeg", "png", "gif", "webp", "svg", "bmp", "ico"]
        case .videos: return ["mp4", "webm", "mkv", "mov", "m4v"]
        case .audio: return ["mp3", "m4a", "wav", "ogg", "flac"]
        case .documents: return ["pdf", "doc", "docx", "txt", "rtf", "csv"]
        case .archives: return ["zip", "tar", "gz", "7z", "rar"]
        case .scripts: return ["js", "mjs"]
        case .stylesheets: return ["css"]
        case .other: return []
        }
    }
}

public struct GrabberItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var url: String
    public var filename: String?
    public var mimeType: String?
    public var selected: Bool
    public var status: String

    public init(id: UUID = UUID(), url: String, filename: String? = nil, mimeType: String? = nil, selected: Bool = true, status: String = "found") {
        self.id = id
        self.url = url
        self.filename = filename
        self.mimeType = mimeType
        self.selected = selected
        self.status = status
    }
}

public struct GrabberProject: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var startURL: String
    public var scope: GrabberScope
    public var resourceTypes: [GrabberResourceType]
    public var maxDepth: Int
    public var maxURLs: Int
    public var destination: String
    public var queueID: UUID?
    public var createdAt: Date
    public var status: String
    public var items: [GrabberItem]

    public init(
        id: UUID = UUID(),
        name: String,
        startURL: String,
        scope: GrabberScope,
        resourceTypes: [GrabberResourceType],
        maxDepth: Int,
        maxURLs: Int,
        destination: String,
        queueID: UUID? = nil,
        createdAt: Date = Date(),
        status: String = "idle",
        items: [GrabberItem] = []
    ) {
        self.id = id
        self.name = name
        self.startURL = startURL
        self.scope = scope
        self.resourceTypes = resourceTypes
        self.maxDepth = maxDepth
        self.maxURLs = maxURLs
        self.destination = destination
        self.queueID = queueID
        self.createdAt = createdAt
        self.status = status
        self.items = items
    }
}
