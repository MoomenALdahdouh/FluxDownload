import Foundation
import FluxDownloadCore
import FluxDownloadBrowserProtocol
import FluxDownloadIPC

@main
enum CLIMain {
    static func main() async {
        do {
            try await run()
        } catch {
            let message = (error as? FluxError)?.userMessage ?? error.localizedDescription
            FileHandle.standardError.write(Data("\(Brand.name): \(message)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let first = args.first else {
            print("\(Brand.name) \(Brand.version)\nUsage:\n  fluxdownload-cli <URL>\n  fluxdownload-cli --pause-all\n  fluxdownload-cli --resume-all\n  fluxdownload-cli --status")
            return
        }
        let token = try IPCToken.loadOrCreate()
        switch first {
        case "--pause-all":
            let envelope = BrowserEnvelope(type: .statusQuery, payload: .empty, extra: "pause-all")
            _ = try send(mutate(envelope, token: token, note: "pause-all"))
            print("Pause requested.")
        case "--resume-all":
            _ = try send(mutate(BrowserEnvelope(type: .statusQuery, payload: .empty), token: token, note: "resume-all"))
            print("Resume requested.")
        case "--status":
            let response = try send(mutate(BrowserEnvelope(type: .statusQuery, payload: .empty), token: token, note: "status"))
            print(response.ok ? "Connected \(response.appVersion ?? "")" : (response.error ?? "Not connected"))
        case "--queue":
            args.removeFirst()
            guard args.count >= 2 else { throw FluxError.configuration("Usage: fluxdownload-cli --queue NAME URL") }
            let url = try URLValidator.parse(args[1])
            let payload = DownloadRequestPayload(url: url.absoluteString, filename: nil, source: .cli)
            let envelope = BrowserEnvelope(type: .downloadRequest, token: token, payload: .download(payload))
            let response = try send(envelope)
            print(response.ok ? "Queued \(response.downloadID ?? "")" : (response.error ?? "Failed"))
        default:
            if first.hasPrefix("-") { throw FluxError.configuration("Unknown option \(first)") }
            let url = try URLValidator.parse(first)
            let payload = DownloadRequestPayload(url: url.absoluteString, source: .cli)
            let envelope = BrowserEnvelope(type: .downloadRequest, token: token, payload: .download(payload))
            let response = try send(envelope)
            if response.ok {
                print("Download \(response.downloadID ?? "")")
            } else {
                throw FluxError.configuration(response.error ?? "Request failed")
            }
        }
    }

    static func send(_ envelope: BrowserEnvelope) throws -> BrowserResponse {
        do {
            return try IPCClient.send(envelope)
        } catch {
            throw FluxError.configuration("Desktop application is not running.")
        }
    }

    static func mutate(_ envelope: BrowserEnvelope, token: String, note: String) -> BrowserEnvelope {
        var copy = envelope
        copy.token = token
        copy.id = note
        return copy
    }
}

extension BrowserEnvelope {
    init(type: BrowserCommandType, payload: BrowserPayload, extra: String) {
        self.init(type: type, id: extra, payload: payload)
    }
}
