import Foundation

public enum FluxError: Error, Sendable, Equatable {
    case invalidURL(String)
    case unsupportedScheme(String)
    case illegalStateTransition(from: DownloadStatus, to: DownloadStatus)
    case downloadNotFound(UUID)
    case queueNotFound(UUID)
    case categoryNotFound(UUID)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case resumeUnavailable
    case accessDenied
    case notFound
    case rateLimited
    case serverFailure(status: Int)
    case timeout
    case connectionReset
    case dnsFailure
    case networkUnavailable
    case cancelled
    case stalled
    case checksumMismatch
    case incompleteFile
    case pathTraversal
    case invalidFilename
    case duplicateDownload
    case protocolError(String)
    case ipcUnauthenticated
    case ipcPayloadTooLarge
    case ipcUnknownCommand(String)
    case protectedMedia
    case unsupportedMedia
    case database(String)
    case filesystem(String)
    case configuration(String)
    case authenticationRequired
    case proxyFailure
    case grabberLimitReached(String)
    case notImplemented(String)

    public var isRetryable: Bool {
        switch self {
        case .timeout, .connectionReset, .dnsFailure, .networkUnavailable, .stalled, .rateLimited:
            return true
        case .serverFailure(let status):
            return status >= 500 || status == 429
        default:
            return false
        }
    }

    public var userMessage: String {
        switch self {
        case .invalidURL:
            return "The address is not a valid download URL."
        case .unsupportedScheme(let scheme):
            return "The \(scheme) protocol is not supported."
        case .illegalStateTransition:
            return "That action is not available in the current download state."
        case .downloadNotFound:
            return "The download could not be found."
        case .queueNotFound:
            return "The queue could not be found."
        case .categoryNotFound:
            return "The category could not be found."
        case .insufficientDiskSpace:
            return "There is not enough free disk space."
        case .resumeUnavailable:
            return "This server does not support resumable downloads."
        case .accessDenied:
            return "The server requires authorization."
        case .notFound:
            return "The file was not found on the server."
        case .rateLimited:
            return "The server asked the app to slow down. Retrying."
        case .serverFailure:
            return "The server reported a temporary problem."
        case .timeout:
            return "The server did not respond within the configured timeout."
        case .connectionReset:
            return "The connection was interrupted."
        case .dnsFailure:
            return "The host name could not be resolved."
        case .networkUnavailable:
            return "The network is unavailable."
        case .cancelled:
            return "The download was cancelled."
        case .stalled:
            return "The download stalled because no data arrived."
        case .checksumMismatch:
            return "The downloaded file did not match the expected checksum."
        case .incompleteFile:
            return "The downloaded file is incomplete."
        case .pathTraversal, .invalidFilename:
            return "The filename is not allowed."
        case .duplicateDownload:
            return "This download is already in the list."
        case .protocolError:
            return "The browser bridge sent an invalid message."
        case .ipcUnauthenticated:
            return "The desktop connection could not be authenticated."
        case .ipcPayloadTooLarge:
            return "The message was too large and was rejected."
        case .ipcUnknownCommand:
            return "The browser bridge sent an unsupported command."
        case .protectedMedia:
            return "Protected or unsupported media source."
        case .unsupportedMedia:
            return "This media source cannot be downloaded by the application."
        case .database:
            return "The download database could not be updated."
        case .filesystem:
            return "The file could not be saved."
        case .configuration:
            return "A setting is invalid."
        case .authenticationRequired:
            return "The server requires authorization."
        case .proxyFailure:
            return "The proxy connection failed."
        case .grabberLimitReached:
            return "The grabber reached its configured safety limit."
        case .notImplemented(let detail):
            return detail
        }
    }

    public var diagnosticDetail: String {
        String(describing: self)
    }
}

extension FluxError: LocalizedError {
    public var errorDescription: String? { userMessage }
}
