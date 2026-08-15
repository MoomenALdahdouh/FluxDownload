import Foundation

public struct DownloadQueue: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var priority: Int
    public var isActive: Bool
    public var maxSimultaneousDownloads: Int
    public var maxConnectionsPerDownload: Int
    public var bandwidthLimitBytesPerSecond: Int64?
    public var automaticStart: Bool
    public var retryLimit: Int
    public var sortOrder: Int
    public var scheduleID: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        priority: Int = 0,
        isActive: Bool = true,
        maxSimultaneousDownloads: Int = 3,
        maxConnectionsPerDownload: Int = 8,
        bandwidthLimitBytesPerSecond: Int64? = nil,
        automaticStart: Bool = true,
        retryLimit: Int = 5,
        sortOrder: Int = 0,
        scheduleID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.priority = priority
        self.isActive = isActive
        self.maxSimultaneousDownloads = maxSimultaneousDownloads
        self.maxConnectionsPerDownload = maxConnectionsPerDownload
        self.bandwidthLimitBytesPerSecond = bandwidthLimitBytesPerSecond
        self.automaticStart = automaticStart
        self.retryLimit = retryLimit
        self.sortOrder = sortOrder
        self.scheduleID = scheduleID
    }

    public static func mainDefault() -> DownloadQueue {
        DownloadQueue(name: "Main", priority: 10, isActive: true, sortOrder: 0)
    }
}

public enum Weekday: Int, Codable, Sendable, CaseIterable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    public var displayName: String {
        switch self {
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        }
    }
}

public struct Schedule: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var startHour: Int
    public var startMinute: Int
    public var stopHour: Int
    public var stopMinute: Int
    public var days: [Weekday]
    public var isRecurring: Bool
    public var oneShotDate: Date?
    public var bandwidthLimitBytesPerSecond: Int64?
    public var queueID: UUID?
    public var quitWhenDone: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        startHour: Int = 0,
        startMinute: Int = 0,
        stopHour: Int = 23,
        stopMinute: Int = 59,
        days: [Weekday] = Weekday.allCases,
        isRecurring: Bool = true,
        oneShotDate: Date? = nil,
        bandwidthLimitBytesPerSecond: Int64? = nil,
        queueID: UUID? = nil,
        quitWhenDone: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.startHour = startHour
        self.startMinute = startMinute
        self.stopHour = stopHour
        self.stopMinute = stopMinute
        self.days = days
        self.isRecurring = isRecurring
        self.oneShotDate = oneShotDate
        self.bandwidthLimitBytesPerSecond = bandwidthLimitBytesPerSecond
        self.queueID = queueID
        self.quitWhenDone = quitWhenDone
    }

    public func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }
        if !isRecurring, let oneShotDate {
            return calendar.isDate(date, inSameDayAs: oneShotDate) && isWithinWindow(date, calendar: calendar)
        }
        let weekday = Weekday(rawValue: calendar.component(.weekday, from: date)) ?? .monday
        guard days.contains(weekday) else { return false }
        return isWithinWindow(date, calendar: calendar)
    }

    private func isWithinWindow(_ date: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let now = hour * 60 + minute
        let start = startHour * 60 + startMinute
        let stop = stopHour * 60 + stopMinute
        if start == stop { return true }
        if start < stop { return now >= start && now < stop }
        return now >= start || now < stop
    }
}
