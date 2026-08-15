import Foundation

/// Well-known locations used by the app, native host, and CLI.
public enum AppPaths: Sendable {
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Brand.supportDirectoryName, isDirectory: true)
    }

    public static var databaseFile: URL {
        applicationSupport.appendingPathComponent(Brand.databaseFileName)
    }

    public static var ipcSocket: URL {
        applicationSupport.appendingPathComponent(Brand.ipcSocketFileName)
    }

    public static var ipcToken: URL {
        applicationSupport.appendingPathComponent(Brand.ipcTokenFileName)
    }

    public static var logsDirectory: URL {
        applicationSupport.appendingPathComponent("Logs", isDirectory: true)
    }

    public static var defaultDownloadDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    public static func ensureSupportDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }
}
