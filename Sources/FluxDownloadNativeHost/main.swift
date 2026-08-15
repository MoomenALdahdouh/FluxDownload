import Foundation
import AppKit
import FluxDownloadCore
import FluxDownloadBrowserProtocol
import FluxDownloadIPC

@main
enum NativeHostMain {
    static func main() {
        setbuf(stdout, nil)
        setbuf(stdin, nil)
        do {
            try run()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            let response = BrowserResponse(id: "host", ok: false, error: message, diagnostic: "host_error")
            if let data = try? JSONEncoder().encode(response) {
                try? NativeMessagingCodec.writeMessage(data, to: FileHandle.standardOutput)
            }
        }
    }

    static func run() throws {
        guard let incoming = try NativeMessagingCodec.readMessage(from: FileHandle.standardInput) else { return }
        var envelope = try BrowserMessageValidator.decode(incoming)
        let token = try IPCToken.loadOrCreate()
        envelope.token = token
        let response: BrowserResponse
        do {
            response = try IPCClient.send(envelope)
        } catch {
            try launchApp()
            var lastError: Error = error
            response = try {
                for _ in 0..<40 {
                    Thread.sleep(forTimeInterval: 0.25)
                    do { return try IPCClient.send(envelope) } catch { lastError = error }
                }
                throw lastError
            }()
        }
        try NativeMessagingCodec.writeMessage(try BrowserMessageValidator.encode(response), to: FileHandle.standardOutput)
    }

    static func launchApp() throws {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let appURL = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if appURL.pathExtension == "app" {
            NSWorkspace.shared.open(appURL)
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Brand.bundleIdentifier) {
            NSWorkspace.shared.open(url)
        }
    }
}
