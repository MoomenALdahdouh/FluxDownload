import XCTest
import FluxDownloadCore
@testable import FluxDownloadBrowserProtocol

final class BrowserProtocolTests: XCTestCase {
    func testDecodesDownloadRequest() throws {
        let json = """
        {"version":1,"type":"download.request","id":"abc","payload":{"url":"https://example.com/file.mp4","pageURL":"https://example.com/watch","referrer":"https://example.com/watch","filename":"file.mp4","mimeType":"video/mp4","source":"chrome","browserRequestId":"9","capture":true}}
        """.data(using: .utf8)!
        let envelope = try BrowserMessageValidator.decode(json)
        XCTAssertEqual(envelope.type, .downloadRequest)
        if case .download(let payload) = envelope.payload {
            XCTAssertTrue(payload.url.contains("example.com"))
        } else {
            XCTFail("Expected download payload")
        }
    }

    func testRejectsFileURL() {
        let json = """
        {"version":1,"type":"download.request","id":"abc","payload":{"url":"file:///etc/passwd","source":"chrome","capture":false}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try BrowserMessageValidator.decode(json))
    }

    func testRejectsUnknownVersion() {
        let json = """
        {"version":99,"type":"ping","id":"abc","payload":{}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try BrowserMessageValidator.decode(json))
    }

    func testNativeMessagingRoundTrip() throws {
        let payload = Data(#"{"ok":true}"#.utf8)
        let pipe = Pipe()
        try NativeMessagingCodec.writeMessage(payload, to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(try NativeMessagingCodec.readMessage(from: pipe.fileHandleForReading), payload)
    }
}
