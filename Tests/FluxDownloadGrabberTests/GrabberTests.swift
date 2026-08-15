import XCTest
import FluxDownloadCore
import FluxDownloadGrabber
import FluxDownloadTestServer

final class GrabberTests: XCTestCase {
    func testDiscoversSamePageResourcesAndHonorsRobots() async throws {
        let html = """
        <html><body>
        <a href="/a.jpg">img</a>
        <a href="/b.mp4">vid</a>
        <a href="/secret/c.pdf">doc</a>
        <a href="https://other.example/x.bin">away</a>
        </body></html>
        """
        let server = try TestHTTPServer(payloadSize: 8, behavior: [
            "/page": .html(html),
            "/robots.txt": .robots("User-agent: *\nDisallow: /secret\n")
        ])
        try await server.start()
        defer { server.stop() }
        let items = try await SiteGrabber().crawl(
            GrabberOptions(
                startURL: server.origin.appendingPathComponent("page"),
                scope: .domain,
                types: [.images, .videos, .documents],
                maxDepth: 0,
                maxURLs: 50,
                delayNanoseconds: 1_000_000,
                respectRobots: true
            )
        )
        XCTAssertTrue(items.contains(where: { $0.url.contains("a.jpg") }))
        XCTAssertTrue(items.contains(where: { $0.url.contains("b.mp4") }))
        XCTAssertFalse(items.contains(where: { $0.url.contains("secret") }))
        XCTAssertFalse(items.contains(where: { $0.url.contains("other.example") }))
    }

    func testCancelStopsCrawl() async throws {
        let html = "<html><body><a href='/a.jpg'>a</a><a href='/b.jpg'>b</a></body></html>"
        let server = try TestHTTPServer(payloadSize: 8, behavior: ["/page": .html(html)])
        try await server.start()
        defer { server.stop() }
        let grabber = SiteGrabber()
        let task = Task {
            try await grabber.crawl(
                GrabberOptions(
                    startURL: server.origin.appendingPathComponent("page"),
                    scope: .domain,
                    types: [.images],
                    maxDepth: 1,
                    delayNanoseconds: 2_000_000_000,
                    respectRobots: false
                )
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await grabber.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as FluxError {
            XCTAssertEqual(error, .cancelled)
        } catch is CancellationError {
            // acceptable
        }
    }
}
