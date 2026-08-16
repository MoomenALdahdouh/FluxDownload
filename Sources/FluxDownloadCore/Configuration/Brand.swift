import Foundation

/// Product identity. Keep renaming to a single file change.
public enum Brand: Sendable {
    public static let name = "FluxDownload"
    public static let bundleIdentifier = "app.fluxdownload.macos"
    public static let nativeMessagingHostName = "com.fluxdownload.native"
    public static let supportDirectoryName = "FluxDownload"
    public static let databaseFileName = "fluxdownload.sqlite"
    public static let ipcSocketFileName = "ipc.sock"
    public static let ipcTokenFileName = "ipc.token"
    public static let partialExtension = "fluxpart"
    public static let version = "0.1.12"
    public static let copyright = "© 2026 Moomen Aldahdouh"
    public static let repositoryURL = "https://github.com/MoomenALdahdouh/FluxDownload"
    public static let supportURL = "https://ko-fi.com/moomenaldahdouh"
    public static let repositoryLink = URL(string: repositoryURL)!
    public static let supportLink = URL(string: supportURL)!
    /// googlevideo and similar CDNs reject a custom product UA with 403.
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.7922.138 Safari/537.36"
}
