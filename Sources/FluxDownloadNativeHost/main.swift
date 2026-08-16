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
        ensureCurrentApp(token: token)
        let response = try sendIPC(envelope)
        try NativeMessagingCodec.writeMessage(try BrowserMessageValidator.encode(response), to: FileHandle.standardOutput)
    }

    static func sendIPC(_ envelope: BrowserEnvelope) throws -> BrowserResponse {
        do {
            return try IPCClient.send(envelope)
        } catch {
            try launchOwnApp()
            var lastError: Error = error
            for _ in 0..<40 {
                Thread.sleep(forTimeInterval: 0.25)
                do { return try IPCClient.send(envelope) } catch { lastError = error }
            }
            throw lastError
        }
    }

    static func ensureCurrentApp(token: String) {
        var ping = BrowserEnvelope(type: .ping, payload: .empty)
        ping.token = token
        let current = try? IPCClient.send(ping)
        if current?.ok == true, current?.appVersion == Brand.version {
            return
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Brand.bundleIdentifier) {
            app.terminate()
        }
        Thread.sleep(forTimeInterval: 0.5)
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Brand.bundleIdentifier) {
            app.forceTerminate()
        }
        try? launchOwnApp()
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            if let pinged = try? IPCClient.send(ping), pinged.appVersion == Brand.version {
                return
            }
        }
    }

    static func launchOwnApp() throws {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let appURL = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if appURL.pathExtension == "app" {
            let config = NSWorkspace.OpenConfiguration()
            let done = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in
                done.signal()
            }
            _ = done.wait(timeout: .now() + 8)
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Brand.bundleIdentifier) {
            NSWorkspace.shared.open(url)
        }
    }
}
