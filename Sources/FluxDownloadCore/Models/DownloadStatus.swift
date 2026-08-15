import Foundation

public enum DownloadStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case queued
    case preparing
    case connecting
    case downloading
    case paused
    case stalled
    case retrying
    case verifying
    case completed
    case failed
    case cancelled
    case removed

    public var id: String { rawValue }

    public var isActive: Bool {
        switch self {
        case .preparing, .connecting, .downloading, .stalled, .retrying, .verifying:
            return true
        default:
            return false
        }
    }

    public var canPause: Bool {
        switch self {
        case .queued, .preparing, .connecting, .downloading, .stalled, .retrying:
            return true
        default:
            return false
        }
    }

    public var canResume: Bool {
        self == .paused || self == .failed
    }

    public var canCancel: Bool {
        switch self {
        case .completed, .cancelled, .removed:
            return false
        default:
            return true
        }
    }

    public var canRetry: Bool {
        self == .failed
    }

    public var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .preparing: return "Preparing"
        case .connecting: return "Connecting"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .stalled: return "Stalled"
        case .retrying: return "Retrying"
        case .verifying: return "Verifying"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .removed: return "Removed"
        }
    }
}

public enum DownloadStateMachine: Sendable {
    public static let allowed: [DownloadStatus: Set<DownloadStatus>] = [
        .queued: [.preparing, .cancelled],
        .preparing: [.connecting, .failed, .cancelled],
        .connecting: [.downloading, .retrying, .failed, .cancelled, .paused],
        .downloading: [.paused, .stalled, .retrying, .verifying, .failed, .cancelled],
        .stalled: [.downloading, .retrying, .paused, .failed, .cancelled],
        .retrying: [.connecting, .failed, .cancelled, .paused],
        .paused: [.queued, .connecting, .cancelled],
        .verifying: [.completed, .failed],
        .completed: [.removed],
        .failed: [.queued, .removed],
        .cancelled: [.removed],
        .removed: []
    ]

    public static func canTransition(from: DownloadStatus, to: DownloadStatus) -> Bool {
        allowed[from]?.contains(to) ?? false
    }

    @discardableResult
    public static func transition(from: DownloadStatus, to: DownloadStatus) throws -> DownloadStatus {
        guard canTransition(from: from, to: to) else {
            throw FluxError.illegalStateTransition(from: from, to: to)
        }
        return to
    }
}
