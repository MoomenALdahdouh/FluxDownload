import Foundation

public struct FileCategory: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var destination: String
    public var extensions: [String]
    public var mimeTypes: [String]
    public var domainRules: [String]
    public var isEnabled: Bool
    public var isBuiltIn: Bool
    public var sortOrder: Int

    public init(
        id: UUID = UUID(),
        name: String,
        destination: String,
        extensions: [String] = [],
        mimeTypes: [String] = [],
        domainRules: [String] = [],
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.destination = destination
        self.extensions = extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        self.mimeTypes = mimeTypes.map { $0.lowercased() }
        self.domainRules = domainRules
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
    }

    public func matches(filename: String, mimeType: String?, host: String?) -> Bool {
        guard isEnabled else { return false }
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if !ext.isEmpty, extensions.contains(ext) { return true }
        if let mimeType, mimeTypes.contains(where: { mimeType.lowercased().hasPrefix($0) }) { return true }
        if let host {
            let lowered = host.lowercased()
            if domainRules.contains(where: { lowered == $0.lowercased() || lowered.hasSuffix("." + $0.lowercased()) }) {
                return true
            }
        }
        return false
    }
}

public enum BuiltInCategories: Sendable {
    public static func defaults(downloadRoot: URL) -> [FileCategory] {
        [
            FileCategory(
                name: "General",
                destination: downloadRoot.path,
                extensions: [],
                mimeTypes: [],
                isBuiltIn: true,
                sortOrder: 0
            ),
            FileCategory(
                name: "Video",
                destination: downloadRoot.appendingPathComponent("Video").path,
                extensions: ["mp4", "mkv", "webm", "mov", "avi", "m4v", "mpeg", "mpg", "ts", "m2ts", "flv", "wmv", "3gp"],
                mimeTypes: ["video/"],
                isBuiltIn: true,
                sortOrder: 1
            ),
            FileCategory(
                name: "Audio",
                destination: downloadRoot.appendingPathComponent("Audio").path,
                extensions: ["mp3", "aac", "m4a", "wav", "flac", "ogg", "opus", "wma", "aiff", "alac"],
                mimeTypes: ["audio/"],
                isBuiltIn: true,
                sortOrder: 2
            ),
            FileCategory(
                name: "Documents",
                destination: downloadRoot.appendingPathComponent("Documents").path,
                extensions: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "csv", "odt", "ods", "odp", "epub", "pages", "numbers", "key"],
                mimeTypes: ["application/pdf", "text/", "application/msword", "application/vnd"],
                isBuiltIn: true,
                sortOrder: 3
            ),
            FileCategory(
                name: "Images",
                destination: downloadRoot.appendingPathComponent("Images").path,
                extensions: ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif", "svg", "ico", "raw", "dng"],
                mimeTypes: ["image/"],
                isBuiltIn: true,
                sortOrder: 4
            ),
            FileCategory(
                name: "Archives",
                destination: downloadRoot.appendingPathComponent("Archives").path,
                extensions: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "iso", "cab"],
                mimeTypes: ["application/zip", "application/x-7z-compressed", "application/x-rar-compressed", "application/gzip"],
                isBuiltIn: true,
                sortOrder: 5
            ),
            FileCategory(
                name: "Applications",
                destination: downloadRoot.appendingPathComponent("Applications").path,
                extensions: ["dmg", "pkg", "app", "mpkg", "exe", "msi", "apk", "ipa"],
                mimeTypes: ["application/x-apple-diskimage", "application/vnd.apple.installer+xml"],
                isBuiltIn: true,
                sortOrder: 6
            ),
            FileCategory(
                name: "Other",
                destination: downloadRoot.appendingPathComponent("Other").path,
                extensions: [],
                mimeTypes: [],
                isBuiltIn: true,
                sortOrder: 7
            )
        ]
    }

    public static func assign(filename: String, mimeType: String?, host: String?, categories: [FileCategory]) -> FileCategory? {
        let sorted = categories.filter(\.isEnabled).sorted { $0.sortOrder < $1.sortOrder }
        let named = sorted.filter { $0.name != "General" && $0.name != "Other" }
        if let match = named.first(where: { $0.matches(filename: filename, mimeType: mimeType, host: host) }) {
            return match
        }
        return sorted.first(where: { $0.name == "General" }) ?? sorted.first
    }
}
