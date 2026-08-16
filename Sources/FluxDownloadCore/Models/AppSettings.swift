import Foundation

public struct AppSettings: Codable, Sendable, Equatable {
    public var launchAtLogin: Bool
    public var launchMinimized: Bool
    public var menuBarEnabled: Bool
    public var menuBarOnly: Bool
    public var notificationsEnabled: Bool
    public var notifyOnComplete: Bool
    public var notifyOnFailure: Bool
    public var defaultDownloadFolder: String
    public var temporaryFolder: String?
    public var duplicatePolicy: DuplicatePolicy
    public var maxConcurrentDownloads: Int
    public var maxConnectionsPerDownload: Int
    public var maxGlobalConnections: Int
    public var globalBandwidthLimit: Int64?
    public var requestTimeoutSeconds: TimeInterval
    public var resourceTimeoutSeconds: TimeInterval
    public var stallTimeoutSeconds: TimeInterval
    public var retryLimit: Int
    public var userAgent: String
    public var clipboardMonitoringEnabled: Bool
    public var browserCaptureEnabled: Bool
    public var browserAskBeforeDownload: Bool
    public var videoPanelEnabled: Bool
    public var autoResumeOnLaunch: Bool
    public var onboardingCompleted: Bool
    public var defaultVideoQuality: String
    public var proxyMode: ProxyMode
    public var proxyHost: String?
    public var proxyPort: Int?
    public var proxyCredentialRef: String?
    public var captureFileTypeFilter: [String]
    public var neverCaptureDomains: [String]
    public var alwaysCaptureDomains: [String]

    public init(
        launchAtLogin: Bool = false,
        launchMinimized: Bool = true,
        menuBarEnabled: Bool = true,
        menuBarOnly: Bool = false,
        notificationsEnabled: Bool = true,
        notifyOnComplete: Bool = true,
        notifyOnFailure: Bool = true,
        defaultDownloadFolder: String = AppPaths.defaultDownloadDirectory.path,
        temporaryFolder: String? = nil,
        duplicatePolicy: DuplicatePolicy = .ask,
        maxConcurrentDownloads: Int = 3,
        maxConnectionsPerDownload: Int = 8,
        maxGlobalConnections: Int = 32,
        globalBandwidthLimit: Int64? = nil,
        requestTimeoutSeconds: TimeInterval = 30,
        resourceTimeoutSeconds: TimeInterval = 0,
        stallTimeoutSeconds: TimeInterval = 20,
        retryLimit: Int = 5,
        userAgent: String = Brand.userAgent,
        clipboardMonitoringEnabled: Bool = false,
        browserCaptureEnabled: Bool = true,
        browserAskBeforeDownload: Bool = true,
        videoPanelEnabled: Bool = true,
        autoResumeOnLaunch: Bool = true,
        onboardingCompleted: Bool = false,
        defaultVideoQuality: String = "best",
        proxyMode: ProxyMode = .system,
        proxyHost: String? = nil,
        proxyPort: Int? = nil,
        proxyCredentialRef: String? = nil,
        captureFileTypeFilter: [String] = [],
        neverCaptureDomains: [String] = [],
        alwaysCaptureDomains: [String] = []
    ) {
        self.launchAtLogin = launchAtLogin
        self.launchMinimized = launchMinimized
        self.menuBarEnabled = menuBarEnabled
        self.menuBarOnly = menuBarOnly
        self.notificationsEnabled = notificationsEnabled
        self.notifyOnComplete = notifyOnComplete
        self.notifyOnFailure = notifyOnFailure
        self.defaultDownloadFolder = defaultDownloadFolder
        self.temporaryFolder = temporaryFolder
        self.duplicatePolicy = duplicatePolicy
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.maxConnectionsPerDownload = maxConnectionsPerDownload
        self.maxGlobalConnections = maxGlobalConnections
        self.globalBandwidthLimit = globalBandwidthLimit
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.resourceTimeoutSeconds = resourceTimeoutSeconds
        self.stallTimeoutSeconds = stallTimeoutSeconds
        self.retryLimit = retryLimit
        self.userAgent = userAgent
        self.clipboardMonitoringEnabled = clipboardMonitoringEnabled
        self.browserCaptureEnabled = browserCaptureEnabled
        self.browserAskBeforeDownload = browserAskBeforeDownload
        self.videoPanelEnabled = videoPanelEnabled
        self.autoResumeOnLaunch = autoResumeOnLaunch
        self.onboardingCompleted = onboardingCompleted
        self.defaultVideoQuality = defaultVideoQuality
        self.proxyMode = proxyMode
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.proxyCredentialRef = proxyCredentialRef
        self.captureFileTypeFilter = captureFileTypeFilter
        self.neverCaptureDomains = neverCaptureDomains
        self.alwaysCaptureDomains = alwaysCaptureDomains
    }
}

public enum ProxyMode: String, Codable, Sendable, CaseIterable {
    case system
    case none
    case http
    case socks

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .none: return "None"
        case .http: return "HTTP"
        case .socks: return "SOCKS"
        }
    }
}
