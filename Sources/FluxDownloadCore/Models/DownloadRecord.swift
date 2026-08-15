import Foundation

public enum DownloadPriority: Int, Codable, Sendable, CaseIterable, Identifiable {
    case low = 0
    case normal = 1
    case high = 2
    case urgent = 3

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        case .urgent: return "Urgent"
        }
    }
}

public enum DuplicatePolicy: String, Codable, Sendable, CaseIterable {
    case ask
    case replace
    case keepBoth
    case rename
    case cancel

    public var displayName: String {
        switch self {
        case .ask: return "Ask"
        case .replace: return "Replace"
        case .keepBoth: return "Keep both"
        case .rename: return "Rename automatically"
        case .cancel: return "Cancel"
        }
    }
}

public enum SegmentStatus: String, Codable, Sendable {
    case pending
    case downloading
    case completed
    case failed
}

public struct DownloadSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var downloadID: UUID
    public var index: Int
    public var offset: Int64
    public var length: Int64
    public var downloaded: Int64
    public var status: SegmentStatus
    public var speed: Int64
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        downloadID: UUID,
        index: Int,
        offset: Int64,
        length: Int64,
        downloaded: Int64 = 0,
        status: SegmentStatus = .pending,
        speed: Int64 = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.downloadID = downloadID
        self.index = index
        self.offset = offset
        self.length = length
        self.downloaded = downloaded
        self.status = status
        self.speed = speed
        self.lastError = lastError
    }

    public var remaining: Int64 { max(0, length - downloaded) }
    public var currentOffset: Int64 { offset + downloaded }
    public var endInclusive: Int64 { offset + length - 1 }
}

public struct DownloadRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var url: String
    public var originalURL: String
    public var finalURL: String?
    public var filename: String
    public var fileExtension: String
    public var mimeType: String?
    public var size: Int64?
    public var downloadedBytes: Int64
    public var status: DownloadStatus
    public var categoryID: UUID?
    public var queueID: UUID?
    public var priority: DownloadPriority
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var saveDirectory: String
    public var temporaryPath: String?
    public var finalPath: String?
    public var referrer: String?
    public var userAgent: String?
    public var credentialRef: String?
    public var cookieRef: String?
    public var retryCount: Int
    public var connectionCount: Int
    public var requestedConnections: Int
    public var resumeSupported: Bool?
    public var serverName: String?
    public var checksumSHA256: String?
    public var errorCode: String?
    public var errorMessage: String?
    public var sourceBrowser: String?
    public var sourcePageURL: String?
    public var browserRequestID: String?
    public var descriptionText: String?
    public var customHeadersJSON: String?
    public var averageSpeed: Int64
    public var peakSpeed: Int64
    public var currentSpeed: Int64

    public init(
        id: UUID = UUID(),
        url: String,
        originalURL: String? = nil,
        finalURL: String? = nil,
        filename: String,
        fileExtension: String = "",
        mimeType: String? = nil,
        size: Int64? = nil,
        downloadedBytes: Int64 = 0,
        status: DownloadStatus = .queued,
        categoryID: UUID? = nil,
        queueID: UUID? = nil,
        priority: DownloadPriority = .normal,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        saveDirectory: String,
        temporaryPath: String? = nil,
        finalPath: String? = nil,
        referrer: String? = nil,
        userAgent: String? = Brand.userAgent,
        credentialRef: String? = nil,
        cookieRef: String? = nil,
        retryCount: Int = 0,
        connectionCount: Int = 0,
        requestedConnections: Int = 8,
        resumeSupported: Bool? = nil,
        serverName: String? = nil,
        checksumSHA256: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        sourceBrowser: String? = nil,
        sourcePageURL: String? = nil,
        browserRequestID: String? = nil,
        descriptionText: String? = nil,
        customHeadersJSON: String? = nil,
        averageSpeed: Int64 = 0,
        peakSpeed: Int64 = 0,
        currentSpeed: Int64 = 0
    ) {
        self.id = id
        self.url = url
        self.originalURL = originalURL ?? url
        self.finalURL = finalURL
        self.filename = filename
        self.fileExtension = fileExtension
        self.mimeType = mimeType
        self.size = size
        self.downloadedBytes = downloadedBytes
        self.status = status
        self.categoryID = categoryID
        self.queueID = queueID
        self.priority = priority
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.saveDirectory = saveDirectory
        self.temporaryPath = temporaryPath
        self.finalPath = finalPath
        self.referrer = referrer
        self.userAgent = userAgent
        self.credentialRef = credentialRef
        self.cookieRef = cookieRef
        self.retryCount = retryCount
        self.connectionCount = connectionCount
        self.requestedConnections = requestedConnections
        self.resumeSupported = resumeSupported
        self.serverName = serverName
        self.checksumSHA256 = checksumSHA256
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.sourceBrowser = sourceBrowser
        self.sourcePageURL = sourcePageURL
        self.browserRequestID = browserRequestID
        self.descriptionText = descriptionText
        self.customHeadersJSON = customHeadersJSON
        self.averageSpeed = averageSpeed
        self.peakSpeed = peakSpeed
        self.currentSpeed = currentSpeed
    }

    public var progress: Double {
        guard let size, size > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(size))
    }

    public var etaSeconds: TimeInterval? {
        guard currentSpeed > 0, let size, size > downloadedBytes else { return nil }
        return Double(size - downloadedBytes) / Double(currentSpeed)
    }
}

public struct DownloadSnapshot: Sendable, Equatable, Identifiable {
    public var record: DownloadRecord
    public var segments: [DownloadSegment]

    public var id: UUID { record.id }

    public init(record: DownloadRecord, segments: [DownloadSegment] = []) {
        self.record = record
        self.segments = segments
    }
}
